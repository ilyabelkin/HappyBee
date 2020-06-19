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
. /opt/scripts/messenger_config.sh

# Pick out id, subject and body from arguments
ID=$1
SUBJECT=$2
BODY=$3

# Trigger Webhook(s) if the event is critical
if [ -n "$WEBHOOK_EVENT" ] && [ "$SUBJECT" != "${SUBJECT%"CRITICAL:"*}" ]; then
    echo -n 'Triggering Webhook Event ' $WEBHOOK_EVENT 2>&1 | logger -t MESSENGER
    curl -X POST -H "Content-Type: application/json" -d '{"value1":"'"$SUBJECT"'","value2":"Check email for more information.","value3":"'"$ID"'"}' https://maker.ifttt.com/trigger/$WEBHOOK_EVENT/with/key/$WEBHOOK_KEY
fi
if [ -n "$WEBHOOK2_EVENT" ] && [ "$SUBJECT" != "${SUBJECT%"CRITICAL:"*}" ]; then
    echo -n 'Triggering Webhook Event ' $WEBHOOK2_EVENT 2>&1 | logger -t MESSENGER
    curl -X POST -H "Content-Type: application/json" -d '{"value1":"'"$SUBJECT"'","value2":"Check email for more information.","value3":"'"$ID"'"}' https://maker.ifttt.com/trigger/$WEBHOOK2_EVENT/with/key/$WEBHOOK2_KEY
fi

# Rate-limit non-critical messages. Only the first message with the same ID within a specifc time interval is delivered
if [ "$SUBJECT" != "${SUBJECT%"ERROR:"*}" ]; then 
RL_LEVEL="ERROR"
elif [ "$SUBJECT" != "${SUBJECT%"WARNING:"*}" ]; then 
RL_LEVEL="WARNING"
elif [ "$SUBJECT" != "${SUBJECT%"INFO:"*}" ]; then 
RL_LEVEL="INFO"
fi

if [ -n "$RL_LEVEL" ] && [ "$(find "${RL_DIR}messenger.${ID}" -type f)" ] && [ ! "$(find "${RL_DIR}messenger.${ID}" -type f -mmin +"${!RL_LEVEL}")" ]; then
echo -n 'Exiting due to rate-limit ' $ID $RL_LEVEL 2>&1 | logger -t MESSENGER
exit 0
fi

# Show that something is happening (-n doesn't send a line feed)
echo -n 'Emailing to ' $RECIPIENT $RECIPIENT2 ' about ' $ID $SUBJECT 2>&1 | logger -t MESSENGER
# Parenthesis to start a "subshell" that will pass commands to openssl through a pipe
(
# This is the Gmail login for your router's special Gmail address
AUTH=$USER
# The FROM line is only "for show" in the email header (the email will come from the Gmail account
# regardless of what you put for the FROM line)
FROM=$AUTH
# We need to generate base64 login and password for openssl session
AUTH64="$(echo -n $AUTH | openssl enc -base64)"
PASS64="$(echo -n $PASS | openssl enc -base64)"
# Time to start talking to Gmail smtp server
echo 'auth login' ; sleep 1 ; \
echo $AUTH64 ; sleep 1 ; \
echo $PASS64 ; sleep 1 ; \
echo 'mail from: <'$FROM'>' ; sleep 1 ; \
echo 'rcpt to: <'$RECIPIENT'>' ; sleep 1 ; \
# add a second recipient if configured
if [ -n "$RECIPIENT2" ]; then
echo 'rcpt to: <'$RECIPIENT2'>' ; sleep 1 ; \
fi
echo 'data' ; sleep 1 ; \
echo 'Subject: '$SUBJECT ; sleep 1 ; \
echo ''; sleep 1; \
echo "$BODY"; \
echo '.' ; sleep 1 ; \
echo 'QUIT') 2>&1 | \
openssl s_client -connect smtp.gmail.com:587 -starttls smtp -crlf -ign_eof -quiet > /dev/null 2>&1
echo ' Email sent!' 2>&1 | logger -t MESSENGER

# save the rate-limit marker
if [ -n "$RL_LEVEL" ]; then
echo -n 'Save rate-limit marker ' $RL_LEVEL "${RL_DIR}messenger.${ID}" 2>&1 | logger -t MESSENGER
touch "${RL_DIR}messenger.${ID}"
fi