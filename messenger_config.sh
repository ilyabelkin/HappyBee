#!/bin/sh
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

# Rate-limit marker directory
RL_DIR="/var/log/"

# Minimum interval before the next delivery, minutes
CRITICAL=0
ERROR=30
WARNING=60
INFO=1440
DEBUG=0
