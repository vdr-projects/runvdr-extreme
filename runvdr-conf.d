#!/bin/bash

ALLSCRIPTS="/etc/runvdr"
ACTIVESCRIPTS="/etc/runvdr/conf.d"
LINKREL="../"

#####################
# OSDServer helpers #
#####################

# convenient return values
true=0
false=1

function error() {
    # Fatal error. Send quit command, close FIFO and terminate netcat
    [ "${reply2xx[0]}" != 202 ] && SendCmd Quit

    exec 3>&-
    exec 4>&-

    kill $pid

    exit 1
}

function ConnectServer() {
    # Connect to the OSDServer

    # Set up temporary fifo and open as file descriptor 3 and 4
    mkfifo --mode=700 /tmp/pipe-in$$ /tmp/pipe-out$$
    exec 3<> /tmp/pipe-in$$
    exec 4<> /tmp/pipe-out$$
    rm /tmp/pipe-in$$ /tmp/pipe-out$$
    
    # Connect to server using the fifo
    { 
        netcat $1 $2
        
        # In case of connection loss:
        echo 499 disconnected
        echo 202 Good Bye.
    } <&3 >&4 &
    pid=$!
    
    # Sending to the server: use >&3
    # Receive from the server: use <&4
}


function ReadReply() {
    # Read a complete server reply until 2xx return code,
    # and store replies in each category by number
    reply2xx=()
    reply3xx=()
    reply4xx=()
    reply5xx=()
    reply6xx=()

    while read -r code line <&4 ; do
        if [ "$OSDSERVER_DEBUG" ] ; then echo "< $code $line" ; fi
        # screen echo
        
        case $code in
            2*)     IFS=$' \t\n\r' reply2xx=($code "$line")
                    ;;
            3*)     IFS=$' \t\n\r' reply3xx=($code $line)
                    ;;
            4*)     IFS=$' \t\n\r' reply4xx=($code "$line")
                    ;;
            5*)     IFS=$' \t\n\r' reply5xx=($code "$line")
                    ;;
            6*)     IFS=$' \t\n\r' reply6xx=($code "$line")
                    ;;
        esac
        [ -n "${reply2xx[0]}" ] && break
    done

    [ -n "${reply4xx[0]}" ] && return $false
    return $true
}

function SendCmd() {
    # Send a command and read the reply

    if [ "$OSDSERVER_DEBUG" ] ; then echo "> $*" ; fi
    # screen echo

    echo "$*" >&3
    # network send

    ReadReply
}

function IsEvent() {
    # Helper to check reply for a certain event

    [ "${reply3xx[0]}" != 300 ] && return $false
    [ "${reply3xx[1]}" != "$1" ] && return $false
    [ "${reply3xx[2]}" != "$2" ] && return $false

    return $true
}


function QuoteString() {
    # Quote arbitrary string for use in '' and ""
    local str="${!1}"
    
    str="${str//'\'/\\\\}"
    str="${str//'\\'/\\\\}"
    # work around bash bug: double quoted '\'
    
    str="${str//\'/$'\\\''}"
    # This is bogus, anyone knows something better to replace ' by \' ?
    
    str="${str//\"/\\\"}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\t'/\\t}"
    
    eval "$1=\$str"
}

function UnquoteString() {
    # Unquote string
    local str="${!1}"

    str="${str//\\r/$'\r'}"
    str="${str//\\n/$'\n'}"
    str="${str//\\t/$'\t'}"
    str="${str//\\\"/\"}"
    str="${str//\\\'/\'}"
    str="${str//\\\\/\\}"

    eval "$1=\$str"
}

#########################
# runvdr-conf.d helpers #
#########################

function GetConfInfo() {
    name=""
    defaultprio=50
    loaded=""
    local tmp
    
    if [ ! -f "$ALLSCRIPTS/$1" ] ; then
        return 1
    fi
    while read -r line ; do
        tmp="${line#\# Plugin name:}"
        if [ "$tmp" != "$line" ] ; then
            name="${tmp# }"
        fi
        tmp="${line#\# Default priority:}"
        if [ "$tmp" != "$line" ] ; then
            tmp="${tmp#\# Default priority:}"
            while [ "${tmp# }" != "$tmp" ] ; do tmp="${tmp# }" ; done
            while [ "${tmp% }" != "$tmp" ] ; do tmp="${tmp% }" ; done
            if [ -z "${tmp#[0-9]}" ] ; then tmp="0$tmp" ; fi
            if [ -z "${tmp#[0-9][0-9]}" ] ; then
                defaultprio="$tmp"
            fi
        fi
    done < "$ALLSCRIPTS/$1"
    if [ -z "$name" ] ; then
        return 1
    fi
    
    tmp=("$ACTIVESCRIPTS"/[0-9][0-9]"$1")
    tmp="${tmp[0]}"
    if [ -f "$tmp" ] ; then
        tmp="${tmp:${#ACTIVESCRIPTS}+1}"
        loaded="${tmp:0:2}"
    fi
    
    return 0
}

function GetAllConfInfo() {
    local glob="*"
    if [ "$1" ] ; then glob="$1" ; fi
    confs=0
    confs_short=()
    confs_name=()
    confs_defaultprio=()
    confs_loaded=()
    local i
    for i in "$ALLSCRIPTS"/$glob ; do
        i="${i:${#ALLSCRIPTS}+1}"
        if [ -f "$ALLSCRIPTS/$i" ] && GetConfInfo "$i" ; then
            confs_short[$confs]="$i"
            confs_name[$confs]="$name"
            confs_defaultprio[$confs]="$defaultprio"
            confs_loaded[$confs]="$loaded"
            let confs++
        fi
    done
}


function Command_Show() {
    GetAllConfInfo "$1"
    
    local i;
    for ((i=0;i<confs;i++)) ; do
        if [ $i -ne 0 ] ; then 
            echo
        fi
        echo "Plugin short name: ${confs_short[i]}"
        echo "Plugin long name : ${confs_name[i]}"
        echo "Default priority : ${confs_defaultprio[i]}"
        echo "Loaded priority  : ${confs_loaded[i]:---}"
    done
}

function Command_Enable() {
    short="$1"
    if [ -z "$short" ] ; then
        echo "Usage: $0 enable conf-name [--prio #]"
        exit 1
    fi
    GetConfInfo "$short" || { echo "Unknown Plugin $short" >&2 ; exit 1 ; }
    newloaded="$loaded"
    if [ -z "$newloaded" ] ; then
        newloaded="$defaultprio"
    fi
    
    if [ "$2" == "--prio" ] ; then
        newloaded="$3"
        while [ "${newloaded# }" != "$newloaded" ] ; do newloaded="${newloaded# }" ; done
        while [ "${newloaded% }" != "$newloaded" ] ; do newloaded="${newloaded% }" ; done
        if [ -z "${newloaded#[0-9]}" ] ; then newloaded="0$newloaded" ; fi
        if [ "${newloaded#[0-9][0-9]}" ] ; then
            echo "Not a valid priority: $3" >&2
            exit 1
        fi
    fi
    echo -n "Enabling $name"
    mkdir -p "$ACTIVESCRIPTS"
    if [ "$loaded" ] ; then
        rm -f "$ACTIVESCRIPTS"/[0-9][0-9]"$short"
    fi
    ln -s "$LINKREL$short" "$ACTIVESCRIPTS/$newloaded$short"
    echo "."
}

function Command_Disable() {
    short="$1"
    if [ -z "$short" ] ; then
        echo "Usage: $0 disable conf-name"
        exit 1
    fi
    GetConfInfo "$short" || { echo "Unknown Plugin $short" >&2 ; exit 1 ; }
    if [ -z "$loaded" ] ; then
        echo "$short is not loaded." >&2
        exit 1
    fi
    echo -n "Disabling $name"
    rm -f "$ACTIVESCRIPTS"/[0-9][0-9]"$short"
    echo "."
}

function Osdserver_edit() {
    local short="${confs_short[$1]}"
    QuoteString short
    local name="${confs_name[$1]}"
    QuoteString name
    local defaultprio="${confs_defaultprio[$1]}"
    local loaded="${confs_loaded[$1]}"
    local enable="Yes"
    if [ -z "$loaded" ] ; then
        enable="No"
        loaded="$defaultprio"
    fi
    
    SendCmd "enterlocal" || return $false
    # Preserve global variable space, so we can re-use 'menu'
    
    SendCmd "menu=New Menu 'Edit $name'" || return $false
    SendCmd "menu.SetColumns 15" || return $false
    SendCmd "menu.EnableEvent keyOk close" || return $false
    
    SendCmd "menu.AddNew OsdItem -unselectable 'Short name:\\t$short'" || return $false
    
    SendCmd "menu.AddNew OsdItem -unselectable 'Long name:\\t$name'" || return $false
    
    SendCmd "menu.AddNew OsdItem -unselectable 'Default priority:\\t$defaultprio'" || return $false
    
    SendCmd "enable=menu.AddNew EditListItem Enabled No Yes -SelectName '$enable'" || return $false
    SendCmd "enable.SetCurrent" || return $false
    
    SendCmd "prio=menu.AddNew EditIntItem -min 0 -max 99 'Current priority:' '$loaded'" || return $false
    
    SendCmd "_focus.addsubmenu menu" || return $false
    SendCmd "menu.show" || return $false
    
    while true; do
        SendCmd "menu.SleepEvent" || return $false

        if IsEvent menu keyOk ; then
            SendCmd "enable.GetValue -name" || return $false
            [ "${reply6xx[0]}" != 600 ] && return $false
            enable="${reply6xx[1]}"
            
            SendCmd "prio.GetValue" || return $false
            [ "${reply6xx[0]}" != 600 ] && return $false
            prio="${reply6xx[1]}"
            
            if [ "$enable" == "Yes" ] ; then
                Command_Enable "$short" --prio "$prio"
                confs_loaded[$1]="$prio"
            elif [ -n "${confs_loaded[$1]}" ] ; then
                Command_Disable "$short"
                confs_loaded[$1]=""
            fi
            
            SendCmd "menu.SendState osBack" || return $false
            SendCmd "delete menu" || return $false    
            SendCmd "leavelocal" || return $false    
            
            return $true
        fi
        if IsEvent menu close ; then
            SendCmd "delete menu" || return $false    
            SendCmd "leavelocal" || return $false    
            return $true
        fi
    done   
}

function Osdserver_main() {
    SendCmd "menu=New Menu 'Runvdr config'" || return $false
    SendCmd "menu.SetColumns 5" || return $false
    SendCmd "menu.EnableEvent close" || return $false
    
    local i;
    local min=0
    local prio
    until [ "$min" -ge 100 ] ; do
        local nextmin=100
        for ((i=0;i<confs;i++)) ; do
            prio="${confs_defaultprio[i]}"
            if [ -n "${confs_loaded[i]}" ] ; then prio=${confs_loaded[i]} ; fi
            
            if [ "$prio" -eq "$min" ] ; then
                SendCmd "conf$i=menu.AddNew OsdItem '${confs_loaded[i]:---}\t${confs_name[i]}'" || return $false
                SendCmd "conf$i.EnableEvent keyOk" || return $false
            fi
            if [ "$prio" -gt "$min" -a "$prio" -lt "$nextmin" ] ; then
                nextmin="$prio"
            fi
        done
        min="$nextmin"
    done
    
    SendCmd "menu.Show" || return $false
    
    while true ; do
        SendCmd "menu.SleepEvent" || return $false
        
        if IsEvent menu close ; then    
            return $true
        fi
        
        if [ "${reply3xx[1]:0:4}" == "conf" -a "${reply3xx[2]}" == "keyOk" ] ; then
            i="${reply3xx[1]:4}"
            Osdserver_edit "$i" || return $false
            SendCmd "conf$i.SetText '${confs_loaded[i]:---}\t${confs_name[i]}'" || return $false
            SendCmd "menu.Show" || return $false
        fi
    done
}

function Osdserver_connect() {
    GetAllConfInfo
    
    ConnectServer localhost 2010
    # Connect to the server process
    
    ReadReply || error
    # Read server welcome
    
    SendCmd "Version 0.1" || error
    # Identify to server with protocol version
    
    Osdserver_main || error
    # Main menu
    
    SendCmd Quit
    # ... and good bye
    
    exec 3>&-
    exec 4>&-
    # close FIFOs
}

function Command_Osdserver() {
    if [ "$1" == "--debug" ] ; then
        OSDSERVER_DEBUG=1
        Osdserver_connect
    else
        Osdserver_connect </dev/null >/dev/null &
    fi
}

if [ "$1" == "show" ] ; then
    shift
    Command_Show "$@"
elif [ "$1" == "enable" ] ; then
    shift
    Command_Enable "$@"
elif [ "$1" == "disable" ] ; then
    shift
    Command_Disable "$@"
elif [ "$1" == "osdserver" ] ; then
    shift
    Command_Osdserver "$@"
else
    test
    echo "Unknown command: $1" >&2
fi

