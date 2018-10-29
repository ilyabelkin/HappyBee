#!/bin/sh
# ### pollinator.sh: poll ecobee API and perform useful bee stuff ###
# To deploy on DD-WRT using GUI, save as custom script in Administration/Commands and run the following command to rename
# mv /tmp/custom.sh /jffs/scripts/pollinator.sh
# Run every 2 minutes: put the settings below in "additional crontab" field and provide the actual path to the directory plus IP addresses
# */2 * * * * root /jffs/scripts/pollinator.sh EcoDir EcoBIP CamIP "/jffs/scripts/messenger.sh arguments" "/jffs/scripts/wemo_control_busyb.sh FurnaceSwitchIP"
# ## Initial setup notes
# ## Register as an ecobee developer, create an application and get the Client ID: https://www.ecobee.com/developers/
# ## Note: a race condition exists when an access token expires when waggler.sh just refreshed it. Some operations would initially fail, but succeed on the next cycle
# ## Note: to debug if something doesn't work in the script, redirect error output to a file: 2>/tmp/stderr.txt, and delete the file after reviewing the problem
# ## A great book on Bourne Shell Scripting: https://en.wikibooks.org/wiki/Bourne_Shell_Scripting
#
# ## TODO: Trigger an emergency procedure (HVAC shut-off) during Smoke/CO events using additional equipment, i.e. Kidde relay interconnect
# COAlarm=(cat ${EcoDir}COAlarm)
# SmokeAlarm=(cat ${EcoDir}SmokeAlarm)
# ## Fire alert and basic emergency procedures are already implemented based on the remote sensors temperature reading, using them as heat detectors

# Get the directory name to be able to read persistent info like tokens (BDance files) and previous occupancy state marker (BHome) from disc.
# ## The directory must already exist
EcoDir="$1"
EcoBIP="$2"
CamIP="$3"
Messenger="$4"
FurnaceControl="$5"

# ## Constants
# Current firmware version
BFirmwareVersion="4.2.0.394"
# Main censor ID
BMainID=ei:0
# Temperature (T) of 41 Fahrenheit(F) or 5 Celsius(C)
FreezingRiskT=410
# 92F/33.3C
FireRiskT=920
# 60.8F/16C
AwayHeatT=608
# 86F/30C
AwayCoolT=860
# 451F/232.7C - At this temperature books will likely spontaneously catch fire
PaperIgnitionT=4510
# The temperature at which lower humidity setting is used: -5C = 23F
FrostT=230
# Target Absolute Humidity (AH) of 9.7 g/m3 equals Relative Humidity (RH) of 50% at 22C
TargetAHNormal=9.7
# Target Absolute Humidity (AH) of 7.76 g/m3 equals Relative Humidity (RH) of 40% at 22C
TargetAHFrost=7.76
VentLow=5
VentMed=15
VentMax=30
# Furnace fan setting in Auto mode
FanInAuto=0
# Links; replace the PowerOffSite with the local electricity provider's Website outages link
EcoBAPI="https://api.ecobee.com/1/thermostat?format=json"
EcoBSite="http://ecobee.com"
EcoBDevSite="https://www.ecobee.com/developers/"
PowerOffSite="https://www.powerstream.ca/power-outages.html"

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

#Start by reading the access token from disc
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
    # $SensorStateAll will contain all the occurences of "value", both temperature and occupancy states (and humidity if present)
    SensorStateAll=$(echo "$RuntimeParameters" | awk -F '[:,]' '/"value"/ {gsub("[[:blank:]\"]+", "", $2); print $2;}')
    OccupancyCnt=$(echo "$SensorStateAll" | awk '/true/ {count++} END {print count}')
    OccupancyState=$(echo "$SensorStateAll" | awk -v FS='\n' '/true/ {os=os FS 1} /false/ {os=os FS 0}; END {print os}')
    # Perform Bitwise OR operation with each sensor state and then compare to the original. 
    # Only changes from unoccupied to occupied will be counted; this will also help ignoring faulty sensors that always report occupancy
    # ## Note: If paste comand is supported by the shell, the more readable code could be used
    # OccupancyTriggered=$(echo "$OccupancyState" | paste BHome - -d ' ' | awk '{if ($1+$2 >=1) o=1; if (o!=$1) {print "true";exit;}}')
    # ## Note: if paste is not supported, the same result could be achieved with native awk
    OccupancyTriggered=$(echo "$OccupancyState" | awk 'NR==FNR{prev[FNR]=$1;next}; {if (prev[FNR]+$1 >= 1) o=1; else o=0; if (o==1 && o!=prev[FNR]) {print "true";exit}}' ${EcoDir}BHome -)

    # Fire temperature treshold: at this point it's assumed the fire is on, and need to switch off the system. This should be tuned for a specific climate
    # An alternative approach that could be used in addition is to check for a smoke/CO alarm, which requires additional equipment
    FireCnt=$(echo "$SensorStateAll" | awk -v FRT=$FireRiskT '(int($1) >= FRT ) {count++} END {print count}')

    # Thermostat name and all sensor names
    SensorNames=$(echo "$RuntimeParameters" | awk -F '[:,]' '/"name"/ {gsub("[[:blank:]\"]+", "", $2); print $2; next}')
else
    "$Messenger" "Alert: missing access token" "See docs at: $EcoBDevSite More info: $RuntimeParameters"
fi

if [ -n "$OccupancyState" ]; then
    # Save the current state for the future
    echo "$OccupancyState" > "${EcoDir}BHome"
    SensorOccupancy=$(echo "$SensorNames" | awk 'NR==FNR{nms[FNR]=$1;next}; {print nms[FNR],$1}' ${EcoDir}BHome -)
    # echo "DEBUG: SensorNames $SensorNames SensorOccupancy $SensorOccupancy" 2>&1 | logger -t POLLINATOR
fi

# Notify about changes in version, just in case: this doesn't protect from API changes, but testing is likely required
if [ -n "$ThermostatFirmwareVersion" ] && [ ! "$ThermostatFirmwareVersion" = "$BFirmwareVersion" ]; then
    "$Messenger" "Alert: Thermostat firmware was updated. Retest all functions!" "New version: $ThermostatFirmwareVersion"
fi

if [ -n "$FireCnt" ]; then
    FnGetAccessToken
    # ## Note: The emergency procedure
    # If one of the sensors temperature >= set fire temperature, switch off heat and set HRV to 0 to restrict oxygen flow
    # Email and set the HVAC system to off mode; ecobee needs manual intervention to start again
    EcoBOff=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22thermostat%22%3A%7B%22settings%22%3A%7B%22hvacMode%22%3A%22off%22%7D%7D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")
    # Check if operation was successful
    EcoBOffStatus=$(FnGetValue "$EcoBOff" message)
    "$Messenger" "Alert: Possible fire!" "$FireCnt sensor(s) report possible fire - temperature over the treshold! Check cameras and call 911 if confirmed. Switching off HVAC system; someone needs to check the location and manually turn them on. Here's all sensors state $SensorNames: $SensorStateAll. False alarm? When there's no fire and the actual temperature is over treshold we need to cool the house down. Switch off the WI-FI router and turn on the Air Conditioner until the temperature is under 30C, then switch the router back on. Additional detail: $RuntimeParameters"
fi
if [ -n "$EcoBOffStatus" ]; then
    "$Messenger" "Alert: Failed to turn HVAC off during a possible fire!" "$EcoBOff"
fi

# if desiredHeat/Cool are already set to target values, just set the flag
if [ -n "$DesiredHeat" ] && [ "$DesiredHeat" -eq "$AwayHeatT" ] && [ "$DesiredCool" -eq "$AwayCoolT" ]; then
    AwayMode=true
elif [ -n "$DesiredHeat" ]; then
    AwayMode=false
fi

# Check if the cam is on
# It's possible to either ping the cam as in the example below, or use curl to receive specific information
if ! ping -c 1 -w 30 "$CamIP" > /dev/null; then 
    CamOn=false
    # echo "DEBUG: CamOn $CamOn" 2>&1 | logger -t POLLINATOR
else
    CamOn=true
fi

# Check if the security was on and only then switch off and send the alert about security being switched off
if [ "$CamOn" = false ] && [ "$AwayMode" = true ]; then
    FnGetAccessToken
    AwayOff=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22functions%22%3A%5B%7B%22type%22%3A%22resumeProgram%22%2C%22params%22%3A%7B%22resumeAll%22%3Afalse%7D%7D%5D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")
    "$Messenger" "Alert: Security switched off." "Someone switched off security. Setting thermostat to Home mode. Occupancy: $SensorOccupancy"
    # Check if operation successful
    AwayOffStatus=$(FnGetValue "$AwayOff" message)
    AwayMode=false
    # echo "DEBUG: OffStatus $AwayOffStatus" 2>&1 | logger -t POLLINATOR
fi
if [ -n "$AwayOffStatus" ]; then
    "$Messenger" "Alert: Failed to switch security off." "$AwayOff. Occupancy: $SensorOccupancy"
fi

# Check if the security was off and only then switch on and send the alert about security being switched on
if [ "$CamOn" = true ] && [ "$AwayMode" = false ]; then
    FnGetAccessToken
    AwayOn=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22functions%22%3A%5B%7B%22type%22%3A%22setHold%22%2C%22params%22%3A%7B%22holdType%22%3A%22indefinite%22%2C%22heatHoldTemp%22%3A608%2C%22coolHoldTemp%22%3A860%7D%7D%5D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")
    "$Messenger" "Alert: Security switched on." "Someone switched on security. Setting thermostat to Away mode. Occupancy: $SensorOccupancy" 
    # Check if operation successful
    AwayOnStatus=$(FnGetValue "$AwayOn" message)
    AwayMode=true
    # echo "DEBUG: OnStatus $AwayOnStatus" 2>&1 | logger -t POLLINATOR
fi
if [ -n "$AwayOnStatus" ]; then
    "$Messenger" "Alert: Failed to switch security on." "$AwayOn. Occupancy: $SensorOccupancy"
fi

# Check if occupancy is triggered during Away
if [ "$AwayMode" = true ] && [ "$OccupancyTriggered" = true ]; then
    # ## Note that RuntimeParameters are not included to allow threading of the emails in an email client in case too many are generated due to faulty sensor(s) state
    "$Messenger" "Alert: $OccupancyCnt sensor(s) report occupancy, check cameras!" "Occupancy: $SensorOccupancy. The sensors might report occupancy for several minutes after the occurence. Here's detailed sensors state: $SensorNames $SensorStateAll."
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
    HRVHome="$VentLow"
fi

if [ "$AwayMode" = true ]; then
    HRVMin="$HRVAway"
    HRVHome="$HRVAway"
    FanInAuto=0
else
    HRVMin="$HRVHome"
fi

# If one of the sensors temperature >= set fire temperature treshold, switch off heat and set HRV to 0 to restrict oxygen flow
# Set furnace fan to 0
# ## Note that in cold weather some ventilators could turn on by themselves for a short period of time to prevent ice build-up in the core (defrost mode). 
# ## This cannot be controlled solely by ecobee, and could cause some fresh air to come in.
# ## The script could also switch off FAN and HRV 20-min timers if they are used, but to introduce less potential complications will not touch these parameters.
# ## Note: cannot set ventilatorMinOnTime to less than 5 min/hour; TODO: need to set to 0 if the behaviour is changed
if [ -n "$FireCnt" ]; then
    HRVAway=0
    HRVHome=0
    HRVMin="$VentLow"
    FanInAuto=0
    MaxVentilate=false
fi

# Only set HRV parameters if they need to be different
if [ -n "$IndoorRH" ] && [ "$VentilatorMinOnTime" -eq "$HRVMin" ] && [ "$VentilatorMinOnTimeHome" -eq "$HRVHome" ] && [ "$VentilatorMinOnTimeAway" -eq "$HRVAway" ] && [ "$FanMinOnTime" -eq "$FanInAuto" ]; then
    # Do nothing, everything is already set correctly
    HRVAlreadySet=true
elif [ -n "$IndoorRH" ]; then
    FnGetAccessToken
    HRVSet=$(curl -s -k --request POST --data "%7B%22selection%22%3A%7B%22selectionType%22%3A%22registered%22%2C%22selectionMatch%22%3A%22%22%7D%2C%22thermostat%22%3A%7B%22settings%22%3A%7B%22ventilatorMinOnTimeHome%22%3A$HRVHome%2C%22ventilatorMinOnTimeAway%22%3A$HRVAway%2C%22ventilatorMinOnTime%22%3A$HRVMin%2C%22fanMinOnTime%22%3A$FanInAuto%7D%7D%7D" -H "Content-Type: application/json;charset=UTF-8" -H "Authorization: Bearer $AccessToken" "$EcoBAPI")
    # Check if operation was successful
    HRVSetStatus=$(FnGetValue "$HRVSet" message)
fi
if [ -n "$HRVSetStatus" ]; then
    "$Messenger" "Alert: Failed to set HRV parameters" "$HRVSet"
fi
# Only notify about Maximum Ventilation once every consecutive cycle starts, otherwise will be emailed every X minutes
if [ -n "$HRVSet" ] && [ "$MaxVentilate" = true ]; then
    # TODO: comment the next line to disable email notifications on start of each ventilation cycle
    "$Messenger" "Alert: Maximum Ventilation mode cycle started" "Great news! The Absolute Humidity outdoors is $OutAH, the target AH is $TargetAH, so the house will be ventilated more to normalize indoor AH ($IndoorAH). Using main thermostat temperature, $(FnToC "$IndoorT"), for the calculation."
    echo "DEBUG: Maximum Ventilation mode cycle started: The Absolute Humidity outdoors is $OutAH, the target AH is $TargetAH, so the house will be ventilated more to normalize indoor AH ($IndoorAH)." 2>&1 | logger -t POLLINATOR
fi

# ## Perform additional ecobee diagnostics
# Check that "hvacMode" is not off|cool) in winter months or when temperature is under a treshold inside or outside. Possible hvacMode values: auto auxHeatOnly cool heat off
# It's possible to switch ecobee on automatically if no fire was detected, but this could prevent maintenance tasks in Winter.
if [ "$FreezingRisk" = true ]; then  
    "$Messenger" "Alert: ecobee thermostat is off in cold weather." "Ecobee thermostat is off or in cool mode during cold weather. In Winter pipes could freeze, please fix on site. Login to $EcoBSite to switch on heat. Additional detail: $RuntimeParameters"
    # echo "DEBUG: RealEmergency $RuntimeParameters" 2>&1 | logger -t POLLINATOR
fi

if ! ping -c 1 -w 30 "$EcoBIP" > /dev/null; then
    EcoBPing=false 
fi

if [ "$EcoBPing" = false ] && [ ! "$EcoBConnected" = true ]; then  
    "$Messenger" "Alert: ecobee thermostat disconnected." "ecobee local network connected status: $EcoBPing. ecobee online connected status: $EcoBConnected. The HVAC could be completely out of power, or ecobee thermostat hangs and the HVAC system needs to be switched off and on again. In Winter pipes could freeze, please fix on site. See $PowerOffSite. Login here to see if functionality was restored $EcoBSite. Additional detail: $RuntimeParameters"
    # echo "DEBUG: RealEmergency $RuntimeParameters" 2>&1 | logger -t POLLINATOR
    # Turn on the furnace if ecobee is hanging after a power surge or short-term outage
    FurnaceState=$(echo $($FurnaceControl getstate))
    FurnaceOn=$(echo $($FurnaceControl on))
    ## Note: "Error" usually means the furnace was already on
    "$Messenger" "Alert: attempting to turn the furnace back on." "Original furnace state: $FurnaceState. New furnace state: $FurnaceOn"
fi