#!/bin/sh
# ### messenger.sh: a special bee that knows how to talk to humans, e.g. through email ###
# Adapted from: http://www.dd-wrt.com/phpBB2/viewtopic.php?t=288339&postdays=0&postorder=asc&start=15
# Save as /opt/scripts/messenger.sh
# This script sends an email through gmail
#
# Note: you must turn ON "Access for less secure apps" in the Gmail settings: or use App Passwords
# https://www.google.com/settings/security/lesssecureapps
# It's recommended you create a separate Gmail account just for your linux device.
#####################################################################################
# ## Note: specify the Google login information in the variables USER and PASS,
# ## as well as the default email address you wish to use in DEFAULT (usually yourself!)
#####################################################################################
# Usage : sh /opt/scripts/messenger.sh  subject body
# subject : Subject of email
# body : Body of email.  Use line feeds \n in body of message to force a carriage return.
#
# The recipient emails, login and password, as well as Webhooks are stored in a configuration file:
. /opt/scripts/happyb_config.sh

# Pick out id, subject and body from arguments
ID=$1
SUBJECT=$2
BODY=$3

# Rate-limit messages. Only the first message with the same ID within a specifc time interval is delivered
if [ "$SUBJECT" != "${SUBJECT%"CRITICAL:"*}" ]; then
    RL_LEVEL="CRITICAL"
    RL_LIMIT=$CRITICAL
elif [ "$SUBJECT" != "${SUBJECT%"ERROR:"*}" ]; then
    RL_LEVEL="ERROR"
    RL_LIMIT=$ERROR
elif [ "$SUBJECT" != "${SUBJECT%"WARNING:"*}" ]; then
    RL_LEVEL="WARNING"
    RL_LIMIT=$WARNING
elif [ "$SUBJECT" != "${SUBJECT%"INFO:"*}" ]; then
    RL_LEVEL="INFO"
    RL_LIMIT=$INFO
fi

if [ -n "$RL_LEVEL" ] && [ "$(find "${EcoDirTemp}messenger.${ID}" -type f)" ] && [ ! "$(find "${EcoDirTemp}messenger.${ID}" -type f -mmin +"$RL_LIMIT")" ]; then
    RL_ON="true"
    # echo -n 'Rate limiting switched on' $ID $RL_LEVEL $RL_LIMIT minutes $RL_ON 2>&1 | logger -t MESSENGER
fi

# Trigger Webhook(s) if the event is critical and not rate-limited
if [ ! -n "$RL_ON" ] && [ -n "$WEBHOOK_EVENT" ] && [ "$RL_LEVEL" = "CRITICAL" ]; then
    echo -n 'Triggering Webhook Event' $WEBHOOK_EVENT 2>&1 | logger -t MESSENGER
    curl -X POST -H "Content-Type: application/json" -d '{"value1":"'"$SUBJECT"'","value2":"Check email for more information.","value3":"'"$ID"'"}' https://maker.ifttt.com/trigger/$WEBHOOK_EVENT/with/key/$WEBHOOK_KEY
fi

if [ ! -n "$RL_ON" ] && [ -n "$WEBHOOK2_EVENT" ] && [ "$RL_LEVEL" = "CRITICAL" ]; then
    echo -n 'Triggering Webhook Event' $WEBHOOK2_EVENT 2>&1 | logger -t MESSENGER
    curl -X POST -H "Content-Type: application/json" -d '{"value1":"'"$SUBJECT"'","value2":"Check email for more information.","value3":"'"$ID"'"}' https://maker.ifttt.com/trigger/$WEBHOOK2_EVENT/with/key/$WEBHOOK2_KEY
fi

# only rate-limit non-critical email
if [ -n "$RL_ON" ] && [ ! "$RL_LEVEL" = "CRITICAL" ]; then
echo -n 'Exiting due to rate-limit' $ID $RL_LEVEL $RL_LIMIT minutes 2>&1 | logger -t MESSENGER
exit 0
fi

# Show that something is happening (-n doesn't send a line feed)
echo -n 'Emailing to ' $RECIPIENT $RECIPIENT2 ' about ' $ID $SUBJECT 2>&1 | logger -t MESSENGER

# Use Postfix email instead of openssl
echo "$BODY" | mail -s $SUBJECT $RECIPIENT1,$RECIPIENT2
echo ' Postfix email sent!' 2>&1 | logger -t MESSENGER

# save the rate-limit marker
if [ ! -n "$RL_ON" ] && [ -n "$RL_LEVEL" ]; then
echo -n 'Save rate-limit marker ' $RL_LEVEL "${EcoDirTemp}messenger.${ID}" 2>&1 | logger -t MESSENGER
touch "${EcoDirTemp}messenger.${ID}"
fi
