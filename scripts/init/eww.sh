mon_count=$1

bar_format="

(defvar workspaceMP1 \"active_workspace\")
(defvar workspaceMP2 \"inactive_workspace\")
(defvar workspaceMP3 \"inactive_workspace\")
(defvar workspaceMP4 \"inactive_workspace\")
(defvar workspaceMP5 \"inactive_workspace\")
(defvar workspaceMP6 \"inactive_workspace\")
(defvar workspaceMP7 \"inactive_workspace\")
(defvar workspaceMP8 \"inactive_workspace\")
(defvar workspaceMP9 \"inactive_workspace\")
(defvar workspaceMP0 \"inactive_workspace\")

(defwidget workspacesMON []
    (box
        :class \"text_widget\"
        :halign \"center\"
        (box :class workspaceMP1 (eventbox :onclick \"echo uwu\" \"1\") )
        (box :class workspaceMP2 (eventbox :onclick \"echo uwu\" \"2\") )
        (box :class workspaceMP3 (eventbox :onclick \"echo uwu\" \"3\") )
        (box :class workspaceMP4 (eventbox :onclick \"echo uwu\" \"4\") )
        (box :class workspaceMP5 (eventbox :onclick \"echo uwu\" \"5\") )
        (box :class workspaceMP6 (eventbox :onclick \"echo uwu\" \"6\") )
        (box :class workspaceMP7 (eventbox :onclick \"echo uwu\" \"7\") )
        (box :class workspaceMP8 (eventbox :onclick \"echo uwu\" \"8\") )
        (box :class workspaceMP9 (eventbox :onclick \"echo uwu\" \"9\") )
        (box :class workspaceMP0 (eventbox :onclick \"echo uwu\" \"0\") )
    )
)

(defwindow barMON
    :geometry
        (geometry
            :x \"10\"
            :y \"10\"
            :height \"42px\"
            :width \"100%\"
            :anchor \"top center\"
        )
    :monitor MON
    :exclusive \"true\"
    :wm-ignore \"false\"
    :windowtype \"dock\"
    :stacking \"fg\"
    (centerbox
        :orientation \"h\"
        :class \"bar\"
        :space-evenly false
        :spacing 10
        (box
            :class \"left\"
            :halign \"start\"
            :spacing 10
            :space-evenly false
            (workspacesMON)
        )
        (box
            :class \"center\"
            :halign \"center\"
            :spacing 10
            :space-evenly false
            (player)
        )
        (box
            :class \"right\"
            :halign \"end\"
            :spacing 10
            :space-evenly false
            (volume)
            $(if [[ -f '/sys/class/power_supply/BAT0/status' ]]; then echo "(battery)"; fi)
            (date)
            (time)
        )
    )
)

"

pkill eww
rm $HOME/.config/eww/eww.yuck
cp $HOME/.config/eww/eww.yuck.template $HOME/.config/eww/eww.yuck

for ((i=0; i<mon_count; i++))
do
    echo $(echo $bar_format | sed "s/MON/$i/g" | sed "s/MP/$(($i+1))/g") >> "$HOME/.config/eww/eww.yuck"
done

eww daemon

for ((i=0; i<mon_count; i++))
do
    eww open bar$i
done
