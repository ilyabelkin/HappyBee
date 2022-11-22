#!/bin/sh
# ### messenger.sh configuration
USER="*@gmail.com"
PASS="******"
# Recipient email addresses
RECIPIENT="*@*.*"
#RECIPIENT2="*@*.*"

# IFTTT Webhook for CRITICAL events. The key is found on Documentation page in IFTTT
WEBHOOK_EVENT="Alarm"
WEBHOOK_KEY="******"
#WEBHOOK2_EVENT="Alarm"
#WEBHOOK2_KEY="******"

# Minimum interval before the next delivery, minutes
CRITICAL=10
ERROR=60
WARNING=360
INFO=1440
DEBUG=0
ALERT=0

# ### waggler.sh configuration
# Get the directory name to be able to store/read persistent info like tokens (BDance files)
# ## The directory must already exist
EcoDir="/opt/scripts/happyb/"
EcoBAuth="https://api.ecobee.com/token"
ClientID="******"

# ### pollinator.sh configuration
# Get the temporary directory name to be able to store/read transient info like occupancy state. /var/log is a good candidate since on many devices it's cached in RAM
# ## The directory must already exist
EcoDirTemp="/var/log/"
EcoBIP="*.*.*.*"
CamIP="*.*.*.*"
CamPollSeconds=20
FurnaceSwitchIP="*.*.*.*"
SecSwIP1="*.*.*.*"
SecSwIP2="*.*.*.*"
SecSwIP3="*.*.*.*"
# ## The command will timeout in 10 seconds if a switch is unresponsive
SecCtrl="timeout 10 sh /opt/scripts/wemo_control_busyb.sh"
FurnaceControl="$SecCtrl $FurnaceSwitchIP"
Messenger="sh /opt/scripts/messenger.sh"

# ## Constants
# Current firmware version
BFirmwareVersion="*.*.*.*"
# Main censor ID
BMainID=ei:0
# Temperature (T) of 41 Fahrenheit(F) or 5 Celsius(C)
FreezingRiskT=410
# 92F/33.3C
FireRiskT=920
# Rate of Rise difference in temperature: standard is 12F/6.7C per minute
RoRT=60
# Default state
AwayMode=false
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
# Ventilator (HRV or ERV) and furnace fan control parameters
VentLow=5
VentMed=10
VentMax=30
FanLow=0
FanMax=60
# Temperature difference between any sensors to trigger recirculation mode, i.e. 3.5C = 6.3F, 4C = 7.2F, 4.5C = 8.1F, 5C = 9.0F
RecircTDelta=81
# Links; replace the PowerOffSite with the local electricity provider's Website outages link
EcoBAPI="https://api.ecobee.com/1/thermostat?format=json"
EcoBSite="http://ecobee.com"
EcoBDevSite="https://www.ecobee.com/developers/"
EcoBStatusSite="https://status.ecobee.com/"
PowerOffSite="https://[your utility power outage page]"
EmergencyPhone="911"
