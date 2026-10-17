#!/bin/bash

directory=$(dirname "$1" | cut -d "/" -f2)
unlink /opt/hypseus-singe/roms
ln -sfv /$directory/alg/roms/ /opt/hypseus-singe/roms
unlink /opt/hypseus-singe/singe
ln -sfv /$directory/alg/ /opt/hypseus-singe/singe

if [[ $1 == "/$directory/alg/Scan_for_new_games.alg" ]]
then
  printf "\033c" >> /dev/tty1
  cd /$directory/alg
  ./Scan_for_new_games.alg
  printf "\n\nFinished scanning the alg folder for games." >> /dev/tty1
  printf "\nPlease restart emulationstaton to find the new shortcuts" >> /dev/tty1
  printf "\ncreated if any.\n" >> /dev/tty1
  sleep 5
  printf "\033c" >> /dev/tty1
  exit 1
fi

HYPSEUS_BIN=/opt/hypseus-singe/hypseus-singe
HYPSEUS_SHARE=/$directory/alg
HYPSEUS_HOME=/opt/hypseus-singe

dir="$1"
basedir=$(basename -- $dir)
SINGEGAME=${basedir%.*}


function STDERR () {
	/bin/cat - 1>&2
}


if [ -z $SINGEGAME ] ; then
	echo "Specify a game to try: " | STDERR
	echo
	echo "$0 [-fullscreen] [-blend] [-nolinear] <gamename>" | STDERR
	echo

        echo "Games available: "
	for game in $(ls $HYPSEUS_SHARE/); do
		if [ $game != "actionmax" ]; then
			installed="$installed $game"
		fi
        done
        echo "$installed" | fold -s -w60 | sed 's/^ //; s/^/\t/' | STDERR
	echo
	exit 1
fi

GAME_DIR="$HYPSEUS_SHARE/$SINGEGAME"
FRAMEFILE="$GAME_DIR/$SINGEGAME.txt"
SINGE_SCRIPT="$GAME_DIR/$SINGEGAME.singe"
ZLUA_ZIP="$GAME_DIR/$SINGEGAME.zip"

if [ ! -f "$FRAMEFILE" ]; then
        echo
        echo "Missing framefile: $FRAMEFILE ?" | STDERR
        echo
        exit 1
fi

if [ -f "$ZLUA_ZIP" ]; then
        LUA_ARG="-zlua $ZLUA_ZIP"
elif [ -f "$SINGE_SCRIPT" ]; then
        LUA_ARG="-script $SINGE_SCRIPT"
else
        echo
        echo "Missing Singe script or zlua zip:" | STDERR
        echo "              $SINGE_SCRIPT ?" | STDERR
        echo "          or  $ZLUA_ZIP ?" | STDERR
        echo
        exit 1
fi

echo "VAR=hypseus-singe" > /home/ark/.config/KILLIT
sudo systemctl restart killer_daemon.service

if [ -f "$GAME_DIR/$SINGEGAME.commands" ]; then
    EXTRAPARAMS=$(<"$GAME_DIR/$SINGEGAME.commands")
fi

if [[ $(cat /sys/class/graphics/fb0/modes | grep -o -P '(?<=:).*(?=p-)') == "720x720" ]]; then
  RES="-x 720 -y 600"
fi

$HYPSEUS_BIN singe vldp \
-gamepad \
-texturestream \
${RES} \
-framefile "$FRAMEFILE" \
$LUA_ARG \
-homedir $HYPSEUS_HOME \
-datadir $HYPSEUS_HOME \
-fullscreen \
$EXTRAPARAMS


EXIT_CODE=$?

if [ "$EXIT_CODE" -ne "0" ] ; then
	if [ "$EXIT_CODE" -eq "127" ]; then
		echo ""
		echo "Hypseus Singe failed to start." | STDERR
		echo "This is probably due to a library problem." | STDERR
		echo "Run hypseus.bin directly to see which libraries are missing." | STDERR
		echo ""
	else
		echo "Loader failed with an unknown exit code : $EXIT_CODE." | STDERR
	fi
	exit $EXIT_CODE
fi
sudo systemctl stop killer_daemon.service
