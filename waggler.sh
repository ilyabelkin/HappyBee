#!/bin/sh
# ### waggler.sh: knows how to refresh ecobee tokens and talk to other bees ###
# ### What is Waggle Dance? Check out https://www.youtube.com/watch?v=LA1OTMCJrT8#t=0m25s ###
# To deploy on DD-WRT using GUI, save as custom script in Administration/Commands and run the following command to rename
# mv /tmp/custom.sh /jffs/scripts/waggler.sh
# Run every 20 minutes: put the settings below in "additional crontab" field and provide the actual path to the directory plus IP addresses
# */20 * * * * root /jffs/scripts/waggler.sh EcoDir ClientID "messenger.sh arguments"
# ## The directory must already exist
EcoDir="$1"
ClientID="$2"
Messenger="$3"
RefreshToken=$(cat ${EcoDir}BDanceR)
EcoBDevSite="https://www.ecobee.com/developers/"
#echo "DEBUG: Retrieved Refresh token from persistent storage: $RefreshToken" 2>&1 | logger -t WAGGLER

# First parameter is the source JSON, and second is the key
# TODO: improve JSON parsing
FnGetValue() {
    JKey="$2"
    echo $(echo "$1" | awk -F '[:,]' '/"'$JKey'"/ {gsub("[[:blank:]\"]+", "", $2); print $2; exit;}')
}

if [ -n "$RefreshToken" ]; then
    # If refresh token is present, get a new access/refresh token pair
    # ## Note -k option is insecure, but necessary on some systems
    TokenPair=$(curl -k -X POST "https://api.ecobee.com/token?grant_type=refresh_token&refresh_token=$RefreshToken&client_id=$ClientID")
else
    "$Messenger" "Alert: Refresh token is missing." "Add the app by PIN, then authorize it, and save the token to the persistent storage: $EcoBDevSite"
fi
TokenPairStatus=$(FnGetValue "$TokenPair" message)
# If the operation was successful, save the token to disc
RefreshTokenNew=$(FnGetValue "$TokenPair" refresh_token)
# Log the info in case the token is not saved to persistent storage
echo "DEBUG: API token response: $TokenPair" 2>&1 | logger -t WAGGLER
if [ -n "$RefreshTokenNew" ]; then
    echo "$RefreshTokenNew" > "${EcoDir}BDanceR"
    AccessToken=$(FnGetValue "$TokenPair" access_token)
    # Save the new AccessToken for the pollinator.sh script
    echo "$AccessToken" > "${EcoDir}BDanceA"
else
    "$Messenger" "Alert: failed to refresh token" "See possible reasons at: $EcoBDevSite More info: $TokenPair"
fi