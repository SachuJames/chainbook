// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainBook} from "../src/ChainBook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deploys two mock tokens and the book, then seeds a small ladder.
/// @dev Keys come from PRIVATE_KEY and SECOND_KEY. The defaults are the first
/// two anvil accounts, which are public development keys: fine on a local
/// node or a testnet demo, worthless anywhere real. Seeding is wrapped so a
/// run that only wants the contracts can set SEED=false.
contract Deploy is Script {
    // anvil account 0 and 1, public on purpose
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", ANVIL_KEY_0);
        uint256 secondKey = vm.envOr("SECOND_KEY", ANVIL_KEY_1);
        address deployer = vm.addr(deployerKey);
        address second = vm.addr(secondKey);
        bool seed = vm.envOr("SEED", true);

        vm.startBroadcast(deployerKey);
        MockERC20 base = new MockERC20("Base Token", "BASE", 18);
        MockERC20 quote = new MockERC20("Quote USD", "QUSD", 18);
        ChainBook book = new ChainBook(address(base), address(quote));
        base.mint(deployer, 10_000 ether);
        quote.mint(deployer, 1_000_000 ether);
        base.mint(second, 10_000 ether);
        quote.mint(second, 1_000_000 ether);
        vm.stopBroadcast();

        console.log("BASE ", address(base));
        console.log("QUSD ", address(quote));
        console.log("BOOK ", address(book));

        if (!seed) return;

        // a small ladder that does not cross: bids at 2.0 and 2.2, asks at 2.6 and 2.8
        vm.startBroadcast(deployerKey);
        quote.approve(address(book), type(uint256).max);
        base.approve(address(book), type(uint256).max);
        book.placeBuy(2.0e18, 50 ether);
        book.placeBuy(2.2e18, 40 ether);
        vm.stopBroadcast();

        vm.startBroadcast(secondKey);
        quote.approve(address(book), type(uint256).max);
        base.approve(address(book), type(uint256).max);
        book.placeSell(2.6e18, 45 ether);
        book.placeSell(2.8e18, 60 ether);
        vm.stopBroadcast();

        console.log("seeded: bids 2.0 x50, 2.2 x40 | asks 2.6 x45, 2.8 x60");
    }
}
