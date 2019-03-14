#!/bin/sh
# ### messenger.sh: a special bee that knows how to talk to humans, e.g. through email ###
# Adapted from: http://www.dd-wrt.com/phpBB2/viewtopic.php?t=288339&postdays=0&postorder=asc&start=15
# Save as /opt/scripts/messenger.sh
# This script sends an email through gmail
# Version 1.1a (uses openssl)
#
# Note: you must turn ON "Access for less secure apps" in the Gmail settings: or use App Passwords
# https://www.google.com/settings/security/lesssecureapps
# It's recommended you create a separate Gmail account just for your linux device.
#####################################################################################
# ## Note: specify the Google login information in the variables USER and PASS,
# ## as well as the default email address you wish to use in DEFAULT (usually yourself!)
#####################################################################################
# Usage : sh /opt/scripts/messenger.sh [recipient] subject body
# recipient : Can be omitted (will send to DEFAULT email address as set in the script)
# subject : Subject of email
# body : Body of email.  Use line feeds \n in body of message to force a carriage return.
#
# The login and password are hard-coded into the script:
USER="******@gmail.com"
PASS="******"
# Default email to send to
DEFAULT="******@gmail.com"
# Let's check if there is a recipient email address (with the @ symbol) -- no pattern matching [[ ]] in ash apparently !
if [ $(echo $1 | grep "@") ]; then
  RECIPIENT=$1
  shift # Move all parameters down one
else # Otherwise send to me by default
  RECIPIENT=$DEFAULT
fi
# Pick out subject and body from arguments
SUBJECT=$1
BODY=$2
# Show that something is happening (-n doesn't send a line feed)
echo -n 'Emailing to ' $RECIPIENT ' about ' $SUBJECT 2>&1 | logger -t MESSENGER
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
echo 'data' ; sleep 1 ; \
echo 'Subject: '$SUBJECT ; sleep 1 ; \
echo ''; sleep 1; \
echo "$BODY"; \
echo '.' ; sleep 1 ; \
echo 'QUIT') 2>&1 | \
openssl s_client -connect smtp.gmail.com:587 -starttls smtp -crlf -ign_eof -quiet > /dev/null 2>&1
echo ' Email sent!' 2>&1 | logger -t MESSENGER