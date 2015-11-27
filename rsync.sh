#!/bin/sh
rsync -av ./ --exclude=hdeploy.ini --delete build.gyg.io:hdeploy-gem/

