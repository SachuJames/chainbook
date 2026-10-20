// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainBook} from "../src/ChainBook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract ChainBookTest is Test {
    ChainBook internal book;
    MockERC20 internal base;
    MockERC20 internal quote;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant PRICE = 2.5e18; // 2.5 quote per base

    function setUp() public {
        base = new MockERC20("Base Token", "BASE", 18);
        quote = new MockERC20("Quote USD", "QUSD", 18);
        book = new ChainBook(address(base), address(quote));

        address[3] memory everyone = [alice, bob, carol];
        for (uint256 i = 0; i < everyone.length; i++) {
            base.mint(everyone[i], 1_000 ether);
            quote.mint(everyone[i], 100_000 ether);
            vm.startPrank(everyone[i]);
            base.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _buy(address who, uint256 price, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return book.placeBuy(price, amount);
    }

    function _sell(address who, uint256 price, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return book.placeSell(price, amount);
    }

    // ---- escrow and resting ----

    function test_BuyEscrowsQuote() public {
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 id = _buy(alice, PRICE, 10 ether);

        assertEq(quote.balanceOf(address(book)), 25 ether, "contract holds the full cost");
        assertEq(quoteBefore - quote.balanceOf(alice), 25 ether);
        ChainBook.Order memory o = book.getOrder(id);
        assertEq(o.remaining, 10 ether);
        assertEq(o.locked, 25 ether);
        assertTrue(o.resting);
        assertEq(book.bestBid(), PRICE);
        assertEq(book.depthAt(ChainBook.Side.Buy, PRICE), 10 ether);
    }

    function test_SellEscrowsBase() public {
        uint256 id = _sell(alice, PRICE, 10 ether);

        assertEq(base.balanceOf(address(book)), 10 ether);
        ChainBook.Order memory o = book.getOrder(id);
        assertEq(o.locked, 10 ether);
        assertTrue(o.resting);
        assertEq(book.bestAsk(), PRICE);
        assertEq(book.depthAt(ChainBook.Side.Sell, PRICE), 10 ether);
    }

    function test_NoCrossNoTrade() public {
        _buy(alice, 2.0e18, 5 ether);
        uint256 id = _sell(bob, 2.4e18, 5 ether);

        ChainBook.Order memory o = book.getOrder(id);
        assertTrue(o.resting);
        assertEq(o.remaining, 5 ether);
        assertEq(book.bestBid(), 2.0e18);
        assertEq(book.bestAsk(), 2.4e18);
        assertEq(book.spread(), 0.4e18);
        assertEq(base.balanceOf(alice), 1_000 ether, "no base moved to the buyer");
        assertEq(base.balanceOf(bob), 1_000 ether - 5 ether, "the seller's base sits in escrow");
    }

    // ---- fills ----

    function test_CrossingBuyFillsAtMakerPrice() public {
        _sell(bob, 2.0e18, 10 ether); // maker ask at 2.0
        uint256 aliceBaseBefore = base.balanceOf(alice);
        uint256 bobQuoteBefore = quote.balanceOf(bob);

        _buy(alice, PRICE, 10 ether); // taker willing to pay 2.5, fills at 2.0

        assertEq(base.balanceOf(alice) - aliceBaseBefore, 10 ether, "buyer got the base");
        assertEq(quote.balanceOf(bob) - bobQuoteBefore, 20 ether, "seller paid at his own price");
        assertEq(quote.balanceOf(alice), 100_000 ether - 20 ether, "price improvement refunded");
        assertEq(book.bestAsk(), 0);
        assertEq(base.balanceOf(address(book)), 0);
        assertEq(quote.balanceOf(address(book)), 0);
    }

    function test_CrossingSellFillsAtMakerPrice() public {
        _buy(alice, PRICE, 10 ether); // maker bid at 2.5, 25 quote locked
        uint256 bobQuoteBefore = quote.balanceOf(bob);

        _sell(bob, 2.0e18, 10 ether); // taker would take 2.0, fills at 2.5

        assertEq(quote.balanceOf(bob) - bobQuoteBefore, 25 ether);
        assertEq(base.balanceOf(alice), 1_000 ether + 10 ether);
        assertEq(book.bestBid(), 0);
        assertEq(quote.balanceOf(address(book)), 0);
    }

    function test_TakerBiggerThanMaker_RemainderRests() public {
        _sell(bob, 2.0e18, 4 ether);
        uint256 takerId = _buy(alice, 2.0e18, 10 ether);

        ChainBook.Order memory o = book.getOrder(takerId);
        assertTrue(o.resting);
        assertEq(o.remaining, 6 ether);
        assertEq(o.locked, 12 ether, "remainder locked at the taker's own price");
        assertEq(book.bestBid(), 2.0e18);
        assertEq(base.balanceOf(alice), 1_000 ether + 4 ether);
    }

    function test_MakerBiggerThanTaker_MakerStaysReduced() public {
        uint256 makerId = _sell(bob, 2.0e18, 10 ether);
        _buy(alice, 2.0e18, 4 ether);

        ChainBook.Order memory o = book.getOrder(makerId);
        assertTrue(o.resting);
        assertEq(o.remaining, 6 ether);
        assertEq(o.locked, 6 ether);
        assertEq(book.depthAt(ChainBook.Side.Sell, 2.0e18), 6 ether);
        assertEq(base.balanceOf(address(book)), 6 ether, "only the unfilled base stays locked");
    }

    function test_PricePriority_BetterLaterOrderFillsFirst() public {
        uint256 worse = _sell(alice, 2.4e18, 5 ether); // placed first, worse price
        uint256 better = _sell(bob, 2.2e18, 5 ether); // placed second, better price

        _buy(carol, PRICE, 5 ether);

        assertEq(book.getOrder(better).remaining, 0, "better price filled");
        assertTrue(book.getOrder(better).resting == false);
        assertEq(book.getOrder(worse).remaining, 5 ether, "worse price untouched");
        assertEq(quote.balanceOf(bob), 100_000 ether + 11 ether, "5 base at 2.2");
    }

    function test_TimePriority_SamePriceFillsInOrder() public {
        uint256 first = _sell(alice, 2.2e18, 5 ether);
        uint256 second = _sell(bob, 2.2e18, 5 ether);

        _buy(carol, 2.2e18, 5 ether);

        assertEq(book.getOrder(first).remaining, 0, "first in line filled");
        assertEq(book.getOrder(second).remaining, 5 ether);
        assertEq(book.depthAt(ChainBook.Side.Sell, 2.2e18), 5 ether);
    }

    function test_BuyWalksLevelsUp() public {
        _sell(alice, 2.0e18, 3 ether);
        _sell(bob, 2.2e18, 3 ether);
        _sell(carol, 2.4e18, 3 ether);

        // alice buys 7; her own ask is skipped, bob and carol fill 6, 1 rests
        uint256 takerId = _buy(alice, 2.4e18, 7 ether);

        assertEq(book.depthAt(ChainBook.Side.Sell, 2.0e18), 3 ether, "own level skipped");
        assertEq(book.depthAt(ChainBook.Side.Sell, 2.2e18), 0);
        assertEq(book.depthAt(ChainBook.Side.Sell, 2.4e18), 0);
        assertEq(book.getOrder(takerId).remaining, 1 ether);
        assertEq(book.bestAsk(), 2.0e18);
        assertEq(book.bestBid(), 2.4e18);
    }

    // ---- cancel ----

    function test_CancelRefundsFully() public {
        uint256 id = _buy(alice, PRICE, 10 ether);
        uint256 before = quote.balanceOf(alice);

        vm.prank(alice);
        book.cancelOrder(id);

        assertEq(quote.balanceOf(alice) - before, 25 ether);
        assertEq(book.bestBid(), 0);
        assertEq(book.getOrder(id).resting, false);
    }

    function test_CancelAfterPartialFillRefundsRemainder() public {
        uint256 id = _sell(bob, 2.0e18, 10 ether);
        _buy(alice, 2.0e18, 4 ether); // fills 4 of 10

        uint256 before = base.balanceOf(bob);
        vm.prank(bob);
        book.cancelOrder(id);

        assertEq(base.balanceOf(bob) - before, 6 ether, "only the unfilled base comes back");
        assertEq(base.balanceOf(address(book)), 0);
    }

    function test_StrangerCannotCancel() public {
        uint256 id = _buy(alice, PRICE, 1 ether);
        vm.prank(bob);
        vm.expectRevert("not the maker");
        book.cancelOrder(id);
    }

    function test_FilledOrderCannotBeCancelled() public {
        uint256 id = _sell(bob, 2.0e18, 5 ether);
        _buy(alice, 2.0e18, 5 ether);
        vm.prank(bob);
        vm.expectRevert("not resting");
        book.cancelOrder(id);
    }

    // ---- self-trade ----

    function test_NoSelfTrade() public {
        uint256 askId = _sell(alice, 2.0e18, 5 ether);
        uint256 bidId = _buy(alice, 2.5e18, 5 ether); // crosses her own ask

        assertEq(book.getOrder(askId).remaining, 5 ether, "own ask untouched");
        ChainBook.Order memory bid = book.getOrder(bidId);
        assertTrue(bid.resting);
        assertEq(bid.remaining, 5 ether);
        assertEq(base.balanceOf(alice), 1_000 ether - 5 ether, "only the escrow moved");
    }

    function test_SelfTradeSkippedButOthersFill() public {
        _sell(alice, 2.0e18, 5 ether); // own ask, cheapest
        _sell(bob, 2.2e18, 5 ether);
        _buy(alice, 2.5e18, 5 ether); // should fill bob, not herself

        assertEq(book.depthAt(ChainBook.Side.Sell, 2.0e18), 5 ether);
        assertEq(book.depthAt(ChainBook.Side.Sell, 2.2e18), 0);
        assertEq(quote.balanceOf(bob), 100_000 ether + 11 ether);
    }

    // ---- reverts ----

    function test_RevertZeroPrice() public {
        vm.prank(alice);
        vm.expectRevert("price is zero");
        book.placeBuy(0, 1 ether);
    }

    function test_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("amount is zero");
        book.placeSell(PRICE, 0);
    }

    function test_RevertInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert();
        book.placeSell(PRICE, 1 ether);
    }

    function test_RevertInsufficientAllowance() public {
        address noApproval = makeAddr("noApproval");
        base.mint(noApproval, 10 ether);
        vm.prank(noApproval);
        vm.expectRevert();
        book.placeSell(PRICE, 1 ether);
    }

    // ---- rounding ----

    function test_RoundingKeepsBooksBalanced() public {
        // price with a repeating cost: 3 base at 0.333... quote
        uint256 price = 333_333_333_333_333_333; // 1/3 scaled by 1e18, roughly
        uint256 makerId = _sell(bob, price, 3 ether);
        _buy(alice, price, 3 ether);

        assertEq(book.getOrder(makerId).remaining, 0);
        assertEq(base.balanceOf(address(book)), 0, "no base stranded");
        assertEq(quote.balanceOf(address(book)), 0, "no quote stranded");
        // bob received floor(3e18 * price / 1e18) = 999_999_999_999_999_999
        assertEq(quote.balanceOf(bob), 100_000 ether + 999_999_999_999_999_999);
    }

    function test_RoundingPartialFillsStayBalanced() public {
        uint256 price = 333_333_333_333_333_333;
        uint256 makerId = _buy(alice, price, 3 ether); // locks floor cost of 3
        uint256 lockedAtStart = book.getOrder(makerId).locked;
        assertEq(lockedAtStart, 999_999_999_999_999_999);

        _sell(bob, price, 1 ether);
        _sell(carol, price, 1 ether);

        ChainBook.Order memory o = book.getOrder(makerId);
        assertEq(o.remaining, 1 ether);
        assertEq(o.locked, book.quoteCost(1 ether, price), "locked equals the cost of what remains");
        assertEq(quote.balanceOf(address(book)), o.locked, "contract holds exactly the obligation");
        assertEq(base.balanceOf(address(book)), 0);
    }
}
