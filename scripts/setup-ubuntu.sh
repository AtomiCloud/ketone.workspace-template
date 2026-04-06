#!/usr/bin/env bash

sudo apt update -y
sudo apt install software-properties-common -y
sudo apt-add-repository "deb [trusted=yes] https://apt.fury.io/atomicloud/ /" -y
sudo apt install cyanprint -y
