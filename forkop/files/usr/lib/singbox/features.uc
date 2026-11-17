#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");

function forkop_tiny() {
    let marker = trim(fs.readfile(constants.SB_VARIANT_STATE_FILE) || "");
    if (marker == "forkop-tiny")
        return true;
    // A package installed outside Forkop can also advertise its build.
    return marker == "" && trim(fs.readfile(constants.SB_FORKOP_VARIANT_FILE) || "") == "tiny";
}

return { forkop_tiny };
