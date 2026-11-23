// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Bases} from "../src/Bases.sol";

contract Deploy is Script {
    function run() external returns (Bases bases) {
        string memory wiki = vm.envOr("BASES_WIKI", string("https://helix.example/wiki/dna:"));
        vm.startBroadcast();
        bases = new Bases(wiki);
        vm.stopBroadcast();
    }
}
