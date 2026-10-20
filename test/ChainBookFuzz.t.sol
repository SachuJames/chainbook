// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainBook} from "../src/ChainBook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Random placements and cancels across three actors. After every run
/// the contract must hold exactly what the resting orders say it owes, and no
/// two different traders may sit crossed (a lone trader may cross himself,
/// because matching skips his own orders by design).
contract ChainBookFuzzTest is Test {
    ChainBook internal book;
    MockERC20 internal base;
    MockERC20 internal quote;
    address[] internal actors;

    function setUp() public {
        base = new MockERC20("Base Token", "BASE", 18);
        quote = new MockERC20("Quote USD", "QUSD", 18);
        book = new ChainBook(address(base), address(quote));

        for (uint256 i = 0; i < 3; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(a);
            base.mint(a, 10_000 ether);
            quote.mint(a, 10_000_000 ether);
            vm.startPrank(a);
            base.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            vm.stopPrank();
        }
    }

    function testFuzz_EscrowInvariant(uint256 seed) public {
        uint256 rng = seed == 0 ? 1 : seed;
        uint256 actions = 6 + (rng % 5); // 6 to 10 actions per run

        for (uint256 step = 0; step < actions; step++) {
            rng = _next(rng);
            address who = actors[rng % actors.length];
            rng = _next(rng);
            uint256 price = 0.5e18 + (rng % 40) * 0.1e18; // 0.5 to 4.4, coarse grid so levels collide
            rng = _next(rng);
            uint256 amount = 1 + (rng % 50); // whole tokens, 1 to 50
            amount *= 1 ether;
            rng = _next(rng);
            uint256 pick = rng % 4;

            vm.startPrank(who);
            if (pick == 0) {
                book.placeBuy(price, amount);
            } else if (pick == 1) {
                book.placeSell(price, amount);
            } else if (pick == 2) {
                // cancel a random resting order of this actor, if any
                uint256 id = _ownRestingId(who, rng);
                if (id != 0) book.cancelOrder(id);
            } else {
                book.placeBuy(price, amount / 2 + 1);
            }
            vm.stopPrank();
        }

        _assertEscrowCoversBook();
        _assertNoCrossBetweenStrangers();
    }

    function _next(uint256 x) internal pure returns (uint256) {
        // xorshift, enough for picking test inputs
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        return x;
    }

    function _ownRestingId(address who, uint256 salt) internal view returns (uint256) {
        uint256 n = book.nextOrderId();
        if (n <= 1) return 0;
        uint256 start = salt % (n - 1) + 1;
        for (uint256 k = 0; k < n - 1; k++) {
            uint256 id = 1 + ((start - 1 + k) % (n - 1));
            ChainBook.Order memory o = book.getOrder(id);
            if (o.resting && o.trader == who) return id;
        }
        return 0;
    }

    function _assertEscrowCoversBook() internal view {
        uint256 baseOwed;
        uint256 quoteOwed;
        uint256 n = book.nextOrderId();
        for (uint256 id = 1; id < n; id++) {
            ChainBook.Order memory o = book.getOrder(id);
            if (!o.resting) continue;
            if (o.side == ChainBook.Side.Sell) {
                baseOwed += o.remaining;
                assertEq(o.locked, o.remaining, "sell escrow is its remainder");
            } else {
                quoteOwed += o.locked;
                assertEq(o.locked, book.quoteCost(o.remaining, o.price), "buy escrow is the cost of its remainder");
            }
            // level depth agrees with the orders in it
        }
        assertEq(base.balanceOf(address(book)), baseOwed, "base in contract equals resting sells");
        assertEq(quote.balanceOf(address(book)), quoteOwed, "quote in contract equals resting buys");
    }

    function _assertNoCrossBetweenStrangers() internal view {
        uint256 n = book.nextOrderId();
        for (uint256 i = 1; i < n; i++) {
            ChainBook.Order memory b = book.getOrder(i);
            if (!b.resting || b.side != ChainBook.Side.Buy) continue;
            for (uint256 j = 1; j < n; j++) {
                ChainBook.Order memory s = book.getOrder(j);
                if (!s.resting || s.side != ChainBook.Side.Sell) continue;
                if (b.trader == s.trader) continue;
                assertLt(b.price, s.price, "strangers rest crossed");
            }
        }
    }
}
