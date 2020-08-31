#!/bin/sh
# ### pollinator.sh: poll ecobee API and perform useful bee stuff ###
# Save as /opt/scripts/pollinator.sh
# Run every 2 minutes: put the settings below in crontab and remember to update parameters in the configuration file
# */2 * * * * root sh /opt/scripts/pollinator.sh
# ## Initial setup notes
# ## Register as an ecobee developer, create an application and get the Client ID: https://www.ecobee.com/developers/
# ## Note: a race condition exists when an access token expires when waggler.sh just refreshed it. Some operations would initially fail, but succeed on the next cycle
# ## Note: to debug if something doesn't work in the script, redirect error output to a file: 2>/tmp/stderr.txt, and delete the file after reviewing the problem
# ## A great book on Bourne Shell Scripting: https://en.wikibooks.org/wiki/Bourne_Shell_Scripting
#
# ## TODO: Trigger an emergency procedure (HVAC shut-off) during Smoke/CO events using additional equipment, i.e. Kidde relay interconnect
# COAlarm=(cat ${EcoDirTemp}COAlarm)
# SmokeAlarm=(cat ${EcoDirTemp}SmokeAlarm)
# ## Fire alert and basic emergency procedures are already implemented based on the remote sensors temperature reading, using them as heat detectors

. /opt/scripts/happyb_config.sh

# Only AccessToken is needed by the pollinator.sh. Both Access and Refresh tokens are retrieved by waggler.sh
# Read the new access token from disk
FnGetAccessToken() {
    AccessTokenNew=$(cat ${EcoDir}BDanceA)
    if [ -n "$AccessTokenNew" ]; then
        AccessToken="$AccessTokenNew"
    else
        echo "DEBUG: couldn't read Access Token from disc" 2>&1 | logger -t POLLINATOR
    fi
}

# Read the Away state from disc
FnGetAwayState() {
    AwayState=$(cat ${EcoDirTemp}BAway)
    if [ -n "$AwayState" ] && [ "$AwayState" -eq 1 ]; then
        AwayMode=true
    else
        AwayMode=false
    fi
}

# First parameter is the source JSON, and second is the key
# ## Note that simply parsing values with AWK is very hacky and relies on the input formatting too much. 
FnGetValue() {
    JKey="$2"
    echo $(echo "$1" | awk -F '[:,]' '/"'$JKey'"/ {gsub("[[:blank:]\"]+", "", $2); print $2; exit;}')
}

# First parameter is the source JSON, second is the key, and third is the pattern
# This is useful when the key value is not unique
# ## Note that simply parsing values with AWK is very hacky and relies on the input formatting too much. 
FnGetValueAfterPattern() {
    JKeyP="$2"
    JPattern="$3"
    # Keep only the contents after pattern matching
    AfterPattern=$(echo "$1" | awk '/"'$JPattern'"/{p=1}p')
    echo $(echo "$AfterPattern" | awk -F '[:,]' '/"'$JKeyP'"/ {gsub("[[:blank:]\"]+", "", $2); print $2; exit;}')
}

# Convert ecobee degrees F*10 to degrees C
FnToC() {
    echo $(echo "$1" | awk '{print ($1/10 - 32)*5/9}')
}

# Convert relative ($) to absolute (g/m3) humidity
FnToAH() {
    echo $(echo "$1 $2" | awk '{print (6.112 * (2.71828 ** ((17.67 * $1)/($1 + 243.5)) * $2 * 2.1674)/(273.15 + $1))}')
}

# Start by reading the access token from disc
FnGetAccessToken

if [ -n "$AccessToken" ]; then
    # Get runtime parameters
    ## Note -k option is insecure, but necessary on some systems
    RuntimeParameters=$(curl -s -k -H "Content-Type: text/json" -H "Authorization: Bearer $AccessToken" "$EcoBAPI"'&body=\{"selection":\{"selectionType":"registered","selectionMatch":"","includeSensors":"true","includeVersion":"true","includeRuntime":"true","includeSettings":"true","includeWeather":"true"\}\}')

    DesiredHeat=$(FnGetValue "$RuntimeParameters" desiredHeat)
    DesiredCool=$(FnGetValue "$RuntimeParameters" desiredCool)
    VentilatorMinOnTimeHome=$(FnGetValue "$RuntimeParameters" ventilatorMinOnTimeHome)
    VentilatorMinOnTimeAway=$(FnGetValue "$RuntimeParameters" ventilatorMinOnTimeAway)
    VentilatorMinOnTime=$(FnGetValue "$RuntimeParameters" ventilatorMinOnTime)
    FanMinOnTime=$(FnGetValue "$RuntimeParameters" fanMinOnTime)
    # IsVentilatorTimerOn=$(FnGetValue "$RuntimeParameters" isVentilatorTimerOn)

    # Only use main thermostat temperature for the calculation, average temperature skews absolute humidity and may cause incorrect operation in some cases
    IndoorT=$(FnGetValueAfterPattern "$RuntimeParameters" value "$BMainID")
    ## Old version that takes average temperature; may be useful as a fallback
    # IndoorT=$(FnGetValue "$RuntimeParameters" actualTemperature)
    IndoorRH=$(FnGetValue "$RuntimeParameters" actualHumidity)
    OutT=$(FnGetValue "$RuntimeParameters" temperature)
    OutRH=$(FnGetValue "$RuntimeParameters" relativeHumidity)
    EcoBConnected=$(FnGetValue "$RuntimeParameters" connected)
    EcoBMode=$(FnGetValue "$RuntimeParameters" hvacMode)
    ThermostatFirmwareVersion=$(FnGetValue "$RuntimeParameters" thermostatFirmwareVersion)

    FreezingRisk=$(echo "$IndoorT $OutT $EcoBMode $FreezingRiskT" | awk '{if (($1 < $4 || $2 < $4) && ($3 == "off" || $3 == "cool" )) print "true"}')
    # ## Currently "value" is only used for sensors temperature and occupancy, with possible values of "true" and "false"
    # $SensorStateAll will contain all the occurences of "value": temperature, occupancy states and humidity if present
    SensorStateAll=$(echo "$RuntimeParameters" | awk -F '[:,]' '/"value"/ {gsub("[[:blank:]\"]+", "", $2); print $2;}')

    OccupancyCnt=$(echo "$SensorStateAll" | awk '/true/ {count++} END {print count}')
    OccupancyState=$(echo "$SensorStateAll" | awk -v FS='\n' '/true/ {os=os FS 1} /false/ {os=os FS 0}; END {print os}')
    # Perform Bitwise OR operation with each sensor state and then compare to the original. 
    # Only changes from unoccupied to occupied will be counted; this will also help ignoring faulty sensors that always report occupancy
    # ## Note: If paste comand is supported by the shell, the more readable code could be used
    # OccupancyTriggered=$(echo "$OccupancyState" | paste BHome - -d ' ' | awk '{if ($1+$2 >=1) o=1; if (o!=$1) {print "true";exit;}}')
    # ## Note: if paste is not supported, the same result could be achieved with native awk
    OccupancyTriggered=$(echo "$OccupancyState" | awk 'NR==FNR{prev[FNR]=$1;next}; {if (prev[FNR]+$1 >= 1) o=1; else o=0; if (o==1 && o!=prev[FNR]) {print "true";exit}}' ${EcoDirTemp}BHome -)

    # Thermostat name and all sensor names
    SensorNames=$(echo "$RuntimeParameters" | awk -F '[:,]' '/"name"/ {gsub("[[:blank:]\"]+", "", $2); print $2; next}')

    # Fire temperature treshold: at this point it's assumed the fire is on, and need to switch off the system. This should be tuned for a specific climate
    # An alternative approach that could be used in addition is to check for a smoke/CO alarm, which requires additional equipment
    FireCnt=$(echo "$SensorStateAll" | awk -v FRT=$FireRiskT '(int($1) >= FRT ) {count++} END {print count}')
    
    # Convert all values to integers, ignore humidity and find the difference between maximum and minimum indoor temperature
    IndoorTDelta=$(echo "$SensorStateAll" | awk 'NR == 1 {max=$1+0 ; min=$1+0} $1+0 >= max+0 {max = $1+0} $1 > 100 && $1 <= min+0 {min = $1+0} END { print max-min+0 }')

    # ## Rate of Rise (RoR) fire detection
    # Humidity is a different order of magnitude and does not affect the calculation
    FireRoRDeltas=$(echo "$SensorStateAll" | awk -v RORT=$RoRT 'NR==FNR{prev[FNR]=$1;next}; { if (int(prev[FNR]) > 100 && int($1) > 100 && int($1)-int(prev[FNR]) >= RORT) {print int($1)-int(prev[FNR])}}' ${EcoDirTemp}BWarm -)
    SensorTHistory=$(echo "$SensorStateAll" | awk -v RORT=$RoRT 'NR==FNR{prev[FNR]=$1;next}; { if (int(prev[FNR]) > 100 && int($1) > 100) {print prev[FNR],$1 }}' ${EcoDirTemp}BWarm -)
   
    # Save the current state for the future
    echo "$SensorStateAll" > "${EcoDirTemp}BWarm"
    # echo "DEBUG: ecobee Mode: $EcoBMode. FireRoRDeltas: $FireRoRDeltas.\n$SensorNames\n$SensorTHistory." 2>&1 | logger -t POLLINATOR
    # $Messenger "poll0010" "DEBUG: Rate of Rise" "ecobee Mode: $EcoBMode. FireRoRDeltas: $FireRoRDeltas.\n$SensorNames\n[Previous] [New] temperature in F*10\n$SensorTHistory."
else
    $Messenger "poll0020" "WARNING: missing access token" "See status and docs at: $EcoBStatusSite and $EcoBDevSite. More info: $RuntimeParameters"
fi

# Set furnace fan run time in Auto mode
if [ "$IndoorTDelta" -gt "$RecircTDelta" ]; then
    FanInAuto="$FanMax"
    # echo "DEBUG: Recirculation mode: true. Temperature difference between sensors in F*10 ($IndoorTDelta) is higher than the treshold ($RecircTDelta); furnace fan is set to recirculate the air. All sensors state: $SensorStateAll."
else
    FanInAuto="$FanLow"
fi

if [ -n "$OccupancyState" ]; then
    # Save the current state for the future
    echo "$OccupancyState" > "${EcoDirTemp}BHome"
    SensorOccupancy=$(echo "$SensorNames" | awk 'NR==FNR{nms[FNR]=$1;next}; {print nms[FNR],$1}' ${EcoDirTemp}BHome -)
    # echo "DEBUG: SensorNames $SensorNames SensorOccupancy $SensorOccupancy" 2>&1 | logger -t POLLINATOR 
fi

# Notify about changes in version, just in case: this doesn't protect from API changes, but testing is likely required
if [ -n "$ThermostatFirmwareVersion" ] && [ ! "$ThermostatFirmwareVersion" = "$BFirmwareVersion" ]; then
    $Messenger "poll0030" "INFO: Thermostat firmware was updated. Retest all functions!" "New version: $ThermostatFirmwareVersion"
fi

if [ -n "$FireCnt" ] || [ -n "$FireRoRDeltas" ]; then
    FnGetAccessToken
    # ## Note: The emergency procedure
    # If one of the sensors temperature >= set fire temperature, switch off HVAC and set HRV to 0 to restrict oxygen flow
    # Email and set the HVAC system to off mode; ecobee needs manual intervention to start again

    # Try to turn all of the equipment including the vent and fan off settings
    EcoBOff=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22thermostat%22%3A%7B%22settings%22%3A%7B%22hvacMode%22%3A%22off%22%2C%22vent%22%3A%22off%22%2C%22smartCirculation%22%3A%22false%22%2C%22ventilatorFreeCooling%22%3A%22false%22%7D%7D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")

    # Check if operation was successful
    EcoBOffStatus=$(FnGetValue "$EcoBOff" message)
    $Messenger "poll0040" "CRITICAL: Possible fire!" "[$FireCnt] fixed point heat sensor(s) report temperature over the treshold. Rate-of-rise heat sensors temperature difference in F*10: $FireRoRDeltas. Check cameras and call $EmergencyPhone if confirmed. Switching off HVAC system; someone needs to check the location and manually turn heat/cool on and remove hold. Here's all sensors state $SensorNames\n[Previous] [New] temperature in F*10\n$SensorTHistory. False alarm? When there's no fire and the actual temperature is over treshold we need to cool the house down. Switch off HappyBee hosting device and turn on the Air Conditioner until the temperature is under 30C, then switch the device back on. More info: $RuntimeParameters"
fi
if [ -n "$EcoBOffStatus" ]; then
    $Messenger "poll0045" "ERROR: Failed to turn HVAC off during a possible fire!" "$EcoBOff"
fi

# Check the current Away state
FnGetAwayState

# Check if the cam is on
# It's possible to either ping the cam as in the example below, or use curl to receive specific information
if ! ping -c 1 -w 20 "$CamIP" > /dev/null; then 
    CamOn=false
    # echo "DEBUG: CamOn $CamOn" 2>&1 | logger -t POLLINATOR
else
    CamOn=true
fi

# Check if the security was on and only then switch off and send the alert about security being switched off
if [ "$CamOn" = false ] && [ "$AwayMode" = true ]; then
    FnGetAccessToken
    AwayOff=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22functions%22%3A%5B%7B%22type%22%3A%22resumeProgram%22%2C%22params%22%3A%7B%22resumeAll%22%3Afalse%7D%7D%5D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")
    $Messenger "poll0050" "ALERT: Security switched off." "Someone switched off security. Setting thermostat to Home mode. Occupancy: $SensorOccupancy"
    # Check if operation successful
    AwayOffStatus=$(FnGetValue "$AwayOff" message)
    AwayMode=false
    # Persist the Away state to disc
    echo "0" > "${EcoDirTemp}BAway"
    # echo "DEBUG: OffStatus $AwayOffStatus" 2>&1 | logger -t POLLINATOR
fi
if [ -n "$AwayOffStatus" ]; then
    $Messenger "poll0055" "ERROR: Failed to switch security off." "$AwayOff. Occupancy: $SensorOccupancy"
fi

# Check if the security was off and only then switch on and send the alert about security being switched on
if [ "$CamOn" = true ] && [ "$AwayMode" = false ]; then
    $Messenger "poll0060" "ALERT: Security switched on." "Someone switched on security. Setting thermostat to Away mode. Occupancy: $SensorOccupancy" 

    AwayMode=true
    AwayModeNew=true
    # Persist the Away state to disc
    echo "1" > "${EcoDirTemp}BAway"
    # echo "DEBUG: OnStatus $AwayOnStatus" 2>&1 | logger -t POLLINATOR
fi

# Check if occupancy is triggered during Away
if [ "$AwayMode" = true ] && [ "$OccupancyTriggered" = true ]; then
    # ## Note that RuntimeParameters are not included to allow threading of the emails in an email client in case too many are generated due to faulty sensor(s) state
    $Messenger "poll0070" "CRITICAL: $OccupancyCnt sensors report occupancy, check cameras!" "Occupancy: $SensorOccupancy. The sensors might report occupancy for several minutes after the occurence. Here's detailed sensors state: $SensorNames\n$SensorStateAll."
fi


# ## Dynamically choose normal or lower humidity target to prevent windows frosting
# ## To apply a frost control algorithm, use lower AH target during extreme cold outside to avoid windows frosting
# ## Here's some info on the frost control: http://www.smarthomehub.net/forums/discussion/204/humidifier-and-window-efficiency
if [ -n "$IndoorRH" ] && [ "$OutT" -lt "$FrostT" ]; then
    TargetAH=$TargetAHFrost
else
    TargetAH=$TargetAHNormal
fi
# echo "DEBUG: TargetAH $TargetAH TargetAHNormal $TargetAHNormal TargetAHFrost $TargetAHFrost OutT $OutT FrostT $FrostT" 2>&1 | logger -t POLLINATOR

# HRV Parameters (Note that ERV may not be efficient for humidity normalization, but humidity problems are also less likely for ERV owners)
if [ -n "$IndoorRH" ]; then
    # Calculate actual Absolute Humidity (AH) using Peter Mander's formula: https://carnotcycle.wordpress.com/2012/08/04/how-to-convert-relative-humidity-to-absolute-humidity/
    IndoorTC=$(FnToC "$IndoorT")
    OutTC=$(FnToC "$OutT")
    IndoorAH=$(FnToAH "$IndoorTC" "$IndoorRH")
    OutAH=$(FnToAH "$OutTC" "$OutRH")

    # if indoor AH < target AH and outdoor AH > indoor AH, or
    # if indoor AH > target AH and outdoor AH < indoor AH, ventilate more
    MaxVentilate=$(echo "$IndoorAH $OutAH $TargetAH" | awk '{if (($1 < $3 && $2 > $1) || ($1 > $3 && $2 < $1)) print "true"}')
    # echo "DEBUG: TargetAH $TargetAH IndoorTC $IndoorTC OutTC $OutTC IndoorAH $IndoorAH, OutAH $OutAH" 2>&1 | logger -t POLLINATOR
fi

if [ "$MaxVentilate" = true ]; then
    HRVAway="$VentMed"
    HRVHome="$VentMax"
else
    HRVAway="$VentLow"
    HRVHome="$VentMed"
fi

if [ "$AwayMode" = true ]; then
    HRVMin="$HRVAway"
    HRVHome="$HRVAway"
    FanInAuto="$FanLow"
    # IsVentilatorTimerOn="false"
else
    HRVMin="$HRVHome"
fi

# If one of the sensors temperature >= set fire temperature treshold, switch off heat and set HRV to 0 to restrict oxygen flow
# Set furnace fan to 0
# ## Note that in cold weather some ventilators could turn on by themselves for a short period of time to prevent ice build-up in the core (defrost mode). 
# ## This cannot be controlled solely by ecobee, and could cause some fresh air to come in.
# ## The script could also switch off FAN and HRV 20-min timers if they are used, but to introduce less potential complications will not touch these parameters.
# ## Note: cannot set ventilatorMinOnTime to less than 5 min/hour; TODO: need to set to 0 if the behaviour is changed
if [ "$EcoBMode" = off ] || [ -n "$FireCnt" ] || [ -n "$FireRoRDeltas" ]; then
    HRVAway=0
    HRVHome=0
    HRVMin="$VentLow"
    FanInAuto="$FanLow"
    MaxVentilate=false
    # IsVentilatorTimerOn="false"
fi

# Only set HRV parameters if they need to be different
if [ -n "$IndoorRH" ] && [ "$VentilatorMinOnTime" -eq "$HRVMin" ] && [ "$VentilatorMinOnTimeHome" -eq "$HRVHome" ] && [ "$VentilatorMinOnTimeAway" -eq "$HRVAway" ] && [ "$FanMinOnTime" -eq "$FanInAuto" ]; then
    # Do nothing, everything is already set correctly. Keep the dummy line below.
    HRVAlreadySet=true
elif [ -n "$IndoorRH" ]; then
    FnGetAccessToken
    # %2C%22isVentilatorTimerOn%22%3A$IsVentilatorTimerOn
    HRVSet=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22thermostat%22%3A%7B%22settings%22%3A%7B%22ventilatorMinOnTimeHome%22%3A$HRVHome%2C%22ventilatorMinOnTimeAway%22%3A$HRVAway%2C%22ventilatorMinOnTime%22%3A$HRVMin%2C%22fanMinOnTime%22%3A$FanInAuto%7D%7D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")

    # Check if operation was successful
    HRVSetStatus=$(FnGetValue "$HRVSet" message)
fi

if [ -n "$HRVSetStatus" ]; then
    $Messenger "poll0080" "WARNING: Failed to set HRV parameters" "See status and docs at: $EcoBStatusSite and $EcoBDevSite. More info: $HRVSet"
fi
# Only notify about Maximum Ventilation once every consecutive cycle starts, otherwise will be emailed every X minutes
if [ -n "$HRVSet" ] && [ "$MaxVentilate" = true ]; then
    # TODO: comment the next line to disable email notifications on start of each ventilation cycle
    # $Messenger "poll0083" "INFO: Maximum Ventilation mode cycle started" "Great news! The Absolute Humidity outdoors is $OutAH, the target AH is $TargetAH, so the house will be ventilated more to normalize indoor AH ($IndoorAH). Using main thermostat temperature, $IndoorTC, for the calculation. Outdoor temperature is $OutTC."
    echo "DEBUG: Maximum Ventilation mode cycle started: The Absolute Humidity outdoors is $OutAH, the target AH is $TargetAH, so the house will be ventilated more to normalize indoor AH ($IndoorAH). Using main thermostat temperature, $IndoorTC, for the calculation. Outdoor temperature is $OutTC." 2>&1 | logger -t POLLINATOR
fi

# ## Set temperature hold and fan mode when Away just switched on or in emergency
# ## Note: the hold has to be set after HRV call to avoid fan always on bug
if [ "$AwayModeNew" = true ] || [ "$EcoBMode" = off ] || [ -n "$FireCnt" ] || [ -n "$FireRoRDeltas" ]; then
    FnGetAccessToken
    # Hold with fan=auto is the only way to reliably set fan to off after setting HRV - this is a workaround for ecobee quirk when fan always runs
    AwayOn=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22functions%22%3A%5B%7B%22type%22%3A%22setHold%22%2C%22params%22%3A%7B%22holdType%22%3A%22indefinite%22%2C%22heatHoldTemp%22%3A$AwayHeatT%2C%22coolHoldTemp%22%3A$AwayCoolT%2C%22fan%22%3A%22auto%22%7D%7D%5D%7D%20" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")

    # Check if operation successful
    AwayOnStatus=$(FnGetValue "$AwayOn" message)
fi

if [ -n "$AwayOnStatus" ]; then
    $Messenger "poll0085" "ERROR: Failed to set temperature hold." "$AwayOn. Occupancy: $SensorOccupancy"
fi

# ## Perform additional ecobee diagnostics
# Check that "hvacMode" is not off|cool) in winter months or when temperature is under a treshold inside or outside. Possible hvacMode values: auto auxHeatOnly cool heat off
# It's possible to switch ecobee on automatically if no fire was detected, but this could prevent maintenance tasks in Winter.
if [ "$FreezingRisk" = true ]; then
    $Messenger "poll0090" "WARNING: ecobee thermostat is off in cold weather." "Ecobee thermostat is off or in cool mode during cold weather. In Winter pipes could freeze, please fix on site. Login to $EcoBSite to switch on heat. Additional detail: $RuntimeParameters"
    # echo "DEBUG: RealEmergency $RuntimeParameters" 2>&1 | logger -t POLLINATOR
fi

if ! ping -c 1 -w 20 "$EcoBIP" > /dev/null; then
    EcoBPing=false
    # $Messenger "poll0101" "INFO: ecobee thermostat disconnected locally." "ecobee local network connected status: $EcoBPing. ecobee online connected status: $EcoBConnected. The HVAC could be completely out of power, or ecobee thermostat hangs and the HVAC system needs to be switched off and on again. In Winter pipes could freeze, please fix on site. See $PowerOffSite. Login here to see if functionality was restored $EcoBSite. See status and docs at: $EcoBStatusSite and $EcoBDevSite. More info: $RuntimeParameters"
fi

if [ "$EcoBPing" = false ] && [ ! "$EcoBConnected" = true ]; then
    $Messenger "poll0100" "WARNING: ecobee thermostat disconnected." "ecobee local network connected status: $EcoBPing. ecobee online connected status: $EcoBConnected. The HVAC could be completely out of power, or ecobee thermostat hangs and the HVAC system needs to be switched off and on again. In Winter pipes could freeze, please fix on site. See $PowerOffSite. Login here to see if functionality was restored $EcoBSite. See status and docs at: $EcoBStatusSite and $EcoBDevSite. More info: $RuntimeParameters"
    # echo "DEBUG: RealEmergency $RuntimeParameters" 2>&1 | logger -t POLLINATOR
    # Decide to turn on the furnace if ecobee is hanging after a power surge or short-term outage
    FurnaceState=$(echo $($FurnaceControl getstate))
else
    FurnaceState="ON"
fi

# Attempt to turn on the furnace if it's not already "ON"
if [ ! "$FurnaceState" = "ON" ]; then
    FurnaceOn=$(echo $($FurnaceControl on))
    $Messenger "poll0110" "WARNING: attempting to turn the furnace back on." "Original furnace state: $FurnaceState. New furnace state: $FurnaceOn"
fi

#$Messenger "poll0200" "DEBUG: runtime parameters" "$RuntimeParameters"
