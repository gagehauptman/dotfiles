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

(defvar workspacewidthMP1 22)
(defvar workspacewidthMP2 13)
(defvar workspacewidthMP3 13)
(defvar workspacewidthMP4 13)
(defvar workspacewidthMP5 13)
(defvar workspacewidthMP6 13)
(defvar workspacewidthMP7 13)
(defvar workspacewidthMP8 13)
(defvar workspacewidthMP9 13)
(defvar workspacewidthMP0 13)

(defwidget startMON []
    (box
        :class \"boxy icon_widget\"
        (eventbox
            \"\"
        )
    )
)

(defwidget workspacesMON []
    (box
        :width 300
        :vexpand false
        :orientation \"h\"
        :class \"workspaces\"
        (centerbox
            (box)
            (box
                :space-evenly false
                :spacing 13
                (box :width workspacewidthMP1 :class workspaceMP1)
                (box :width workspacewidthMP2 :class workspaceMP2)
                (box :width workspacewidthMP3 :class workspaceMP3)
                (box :width workspacewidthMP4 :class workspaceMP4)
                (box :width workspacewidthMP5 :class workspaceMP5)
                (box :width workspacewidthMP6 :class workspaceMP6)
                (box :width workspacewidthMP7 :class workspaceMP7)
                (box :width workspacewidthMP8 :class workspaceMP8)
                (box :width workspacewidthMP9 :class workspaceMP9)
                (box :width workspacewidthMP0 :class workspaceMP0)
            )
            (box)
        )
    )
)

(defwindow barMON
    :geometry
        (geometry
            :x \"0\"
            :y \"0\"
            :height \"40px\"
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
            (startMON)
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
