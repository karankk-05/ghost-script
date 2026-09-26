#!/bin/bash

# Check if GhostScreen is running
if pgrep -x "GhostScreen" > /dev/null
then
    # It is running -> kill it
    killall GhostScreen
else
    # It is not running -> open it in the background (-g)
    open -g -a "GhostScreen" "/Users/karan/Documents/lesss_gooo/delivery/margherita_pizza.md"
fi
