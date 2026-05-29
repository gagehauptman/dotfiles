// Color singleton. Set `flavor` to reskin.
pragma Singleton
import Quickshell

Singleton {
    id: root

    // "mocha" | "latte" | "frappe" | "macchiato"
    property string flavor: "mocha"

    readonly property ColorTheme colors: {
        switch (flavor) {
        case "latte":     return latte;
        case "frappe":    return frappe;
        case "macchiato": return macchiato;
        case "mocha":
        default:          return mocha;
        }
    }

    readonly property CatppuccinMocha mocha: CatppuccinMocha {}
    readonly property CatppuccinLatte latte: CatppuccinLatte {}
    readonly property CatppuccinFrappe frappe: CatppuccinFrappe {}
    readonly property CatppuccinMacchiato macchiato: CatppuccinMacchiato {}
}
