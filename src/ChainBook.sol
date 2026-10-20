// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ChainBook
/// @notice A limit order book for one token pair. Funds are escrowed in the
/// contract, fills settle immediately, and matching is price first, then time.
/// @dev Prices are quote tokens per one whole base token, scaled by 1e18. So a
/// price of 2.5e18 means 2.5 quote for 1 base, whatever the token decimals are.
contract ChainBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Buy,
        Sell
    }

    struct Order {
        uint256 id;
        address trader;
        Side side;
        uint256 price;
        uint256 amount; // base amount originally placed
        uint256 remaining; // base amount still unfilled
        uint256 locked; // escrow backing the remainder: quote for buys, base for sells
        uint256 prevId; // FIFO queue links inside the price level
        uint256 nextId;
        bool resting;
    }

    struct Level {
        bool exists;
        uint256 prevPrice; // next level towards the best price
        uint256 nextPrice;
        uint256 headId;
        uint256 tailId;
        uint256 total; // sum of remaining base at this price
    }

    uint256 public constant PRICE_SCALE = 1e18;

    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) internal _orders;
    mapping(Side => mapping(uint256 => Level)) internal _levels;
    mapping(Side => uint256) internal _best; // best price per side, 0 when empty

    event OrderPlaced(uint256 indexed id, address indexed trader, Side side, uint256 price, uint256 amount);
    event Trade(
        uint256 indexed makerOrderId, uint256 indexed takerOrderId, uint256 price, uint256 baseAmount, uint256 quoteAmount
    );
    event OrderCancelled(uint256 indexed id, address indexed trader, uint256 baseRefunded, uint256 quoteRefunded);

    constructor(address base_, address quote_) {
        require(base_ != address(0) && quote_ != address(0), "zero token");
        require(base_ != quote_, "same token");
        baseToken = IERC20(base_);
        quoteToken = IERC20(quote_);
    }

    /// @notice Quote cost of `amount` of base at `price`, rounded down.
    /// @dev A resting buy pays out of its own escrow: each fill releases the
    /// locked amount minus the cost of what is left, so rounding dust stays in
    /// the maker's escrow and leaves with the final fill or a cancel. The
    /// contract never owes out more than it holds.
    function quoteCost(uint256 amount, uint256 price) public pure returns (uint256) {
        return Math.mulDiv(amount, price, PRICE_SCALE);
    }

    function placeBuy(uint256 price, uint256 amount) external nonReentrant returns (uint256 id) {
        require(price > 0, "price is zero");
        require(amount > 0, "amount is zero");
        uint256 cost = quoteCost(amount, price);
        quoteToken.safeTransferFrom(msg.sender, address(this), cost);

        id = nextOrderId++;
        Order storage o = _orders[id];
        o.id = id;
        o.trader = msg.sender;
        o.side = Side.Buy;
        o.price = price;
        o.amount = amount;
        o.remaining = amount;
        o.locked = cost;
        emit OrderPlaced(id, msg.sender, Side.Buy, price, amount);

        _matchBuy(o);

        if (o.remaining == 0) {
            // filled in full: hand back whatever price improvement left behind
            if (o.locked > 0) {
                uint256 refund = o.locked;
                o.locked = 0;
                quoteToken.safeTransfer(msg.sender, refund);
            }
        } else {
            // keep exactly the cost of the remainder locked, refund the rest
            uint256 keep = quoteCost(o.remaining, price);
            if (o.locked > keep) {
                uint256 refund = o.locked - keep;
                o.locked = keep;
                quoteToken.safeTransfer(msg.sender, refund);
            }
            _rest(o);
        }
    }

    function placeSell(uint256 price, uint256 amount) external nonReentrant returns (uint256 id) {
        require(price > 0, "price is zero");
        require(amount > 0, "amount is zero");
        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        id = nextOrderId++;
        Order storage o = _orders[id];
        o.id = id;
        o.trader = msg.sender;
        o.side = Side.Sell;
        o.price = price;
        o.amount = amount;
        o.remaining = amount;
        o.locked = amount;
        emit OrderPlaced(id, msg.sender, Side.Sell, price, amount);

        _matchSell(o);

        if (o.remaining > 0) {
            _rest(o);
        }
    }

    function cancelOrder(uint256 id) external nonReentrant {
        Order storage o = _orders[id];
        require(o.trader == msg.sender, "not the maker");
        require(o.resting, "not resting");

        _levels[o.side][o.price].total -= o.remaining;
        _unlink(o);
        o.resting = false;
        o.remaining = 0;

        uint256 refund = o.locked;
        o.locked = 0;
        if (o.side == Side.Buy) {
            quoteToken.safeTransfer(msg.sender, refund);
            emit OrderCancelled(id, msg.sender, 0, refund);
        } else {
            baseToken.safeTransfer(msg.sender, refund);
            emit OrderCancelled(id, msg.sender, refund, 0);
        }
    }

    // ---- matching ----

    // Walk ask levels from the best up while they cross the taker's price.
    // Orders from the taker's own account are skipped, never filled against.
    function _matchBuy(Order storage taker) internal {
        uint256 levelPrice = _best[Side.Sell];
        while (taker.remaining > 0 && levelPrice != 0 && levelPrice <= taker.price) {
            uint256 nextLevel = _levels[Side.Sell][levelPrice].nextPrice;
            uint256 oid = _levels[Side.Sell][levelPrice].headId;
            while (taker.remaining > 0 && oid != 0) {
                Order storage maker = _orders[oid];
                uint256 nextOid = maker.nextId;
                if (maker.trader != taker.trader) {
                    _fillFromSell(maker, taker);
                }
                oid = nextOid;
            }
            levelPrice = nextLevel;
        }
    }

    function _matchSell(Order storage taker) internal {
        uint256 levelPrice = _best[Side.Buy];
        while (taker.remaining > 0 && levelPrice != 0 && levelPrice >= taker.price) {
            uint256 nextLevel = _levels[Side.Buy][levelPrice].nextPrice;
            uint256 oid = _levels[Side.Buy][levelPrice].headId;
            while (taker.remaining > 0 && oid != 0) {
                Order storage maker = _orders[oid];
                uint256 nextOid = maker.nextId;
                if (maker.trader != taker.trader) {
                    _fillFromBuy(maker, taker);
                }
                oid = nextOid;
            }
            levelPrice = nextLevel;
        }
    }

    // Taker buy takes from a resting sell, at the maker's price.
    function _fillFromSell(Order storage maker, Order storage taker) internal {
        uint256 fill = maker.remaining < taker.remaining ? maker.remaining : taker.remaining;
        uint256 pay = quoteCost(fill, maker.price);

        maker.remaining -= fill;
        maker.locked -= fill;
        _levels[Side.Sell][maker.price].total -= fill;
        taker.remaining -= fill;
        taker.locked -= pay;
        if (maker.remaining == 0) {
            _unlink(maker);
            maker.resting = false;
        }

        emit Trade(maker.id, taker.id, maker.price, fill, pay);
        baseToken.safeTransfer(taker.trader, fill);
        quoteToken.safeTransfer(maker.trader, pay);
    }

    // Taker sell hits a resting buy. The maker pays out of its escrow, so the
    // seller receives whatever the escrow releases for this fill.
    function _fillFromBuy(Order storage maker, Order storage taker) internal {
        uint256 fill = maker.remaining < taker.remaining ? maker.remaining : taker.remaining;
        uint256 pay = maker.locked - quoteCost(maker.remaining - fill, maker.price);

        maker.remaining -= fill;
        maker.locked -= pay;
        _levels[Side.Buy][maker.price].total -= fill;
        taker.remaining -= fill;
        taker.locked -= fill;
        if (maker.remaining == 0) {
            _unlink(maker);
            maker.resting = false;
        }

        emit Trade(maker.id, taker.id, maker.price, fill, pay);
        quoteToken.safeTransfer(taker.trader, pay);
        baseToken.safeTransfer(maker.trader, fill);
    }

    // ---- book structure ----

    function _rest(Order storage o) internal {
        _ensureLevel(o.side, o.price);
        Level storage lvl = _levels[o.side][o.price];
        lvl.total += o.remaining;
        if (lvl.tailId != 0) {
            _orders[lvl.tailId].nextId = o.id;
            o.prevId = lvl.tailId;
            lvl.tailId = o.id;
        } else {
            lvl.headId = o.id;
            lvl.tailId = o.id;
        }
        o.resting = true;
    }

    function _unlink(Order storage o) internal {
        Level storage lvl = _levels[o.side][o.price];
        if (o.prevId != 0) {
            _orders[o.prevId].nextId = o.nextId;
        } else {
            lvl.headId = o.nextId;
        }
        if (o.nextId != 0) {
            _orders[o.nextId].prevId = o.prevId;
        } else {
            lvl.tailId = o.prevId;
        }
        o.prevId = 0;
        o.nextId = 0;
        if (lvl.headId == 0) {
            _removeLevel(o.side, o.price);
        }
    }

    // Levels sit in a linked list sorted best first: descending for bids,
    // ascending for asks. Inserting a new price walks the list from the best,
    // so the cost grows with the number of distinct prices already resting.
    function _ensureLevel(Side side, uint256 price) internal {
        if (_levels[side][price].exists) return;
        _levels[side][price].exists = true;

        uint256 bestPrice = _best[side];
        if (bestPrice == 0) {
            _best[side] = price;
            return;
        }
        bool buySide = side == Side.Buy;
        if (buySide ? price > bestPrice : price < bestPrice) {
            _levels[side][price].nextPrice = bestPrice;
            _levels[side][bestPrice].prevPrice = price;
            _best[side] = price;
            return;
        }
        uint256 cur = bestPrice;
        uint256 nxt = _levels[side][cur].nextPrice;
        while (nxt != 0 && (buySide ? nxt > price : nxt < price)) {
            cur = nxt;
            nxt = _levels[side][cur].nextPrice;
        }
        _levels[side][price].prevPrice = cur;
        _levels[side][price].nextPrice = nxt;
        _levels[side][cur].nextPrice = price;
        if (nxt != 0) {
            _levels[side][nxt].prevPrice = price;
        }
    }

    function _removeLevel(Side side, uint256 price) internal {
        Level storage lvl = _levels[side][price];
        uint256 prev = lvl.prevPrice;
        uint256 next = lvl.nextPrice;
        if (prev != 0) {
            _levels[side][prev].nextPrice = next;
        } else {
            _best[side] = next;
        }
        if (next != 0) {
            _levels[side][next].prevPrice = prev;
        }
        delete _levels[side][price];
    }

    // ---- views ----

    function bestBid() external view returns (uint256) {
        return _best[Side.Buy];
    }

    function bestAsk() external view returns (uint256) {
        return _best[Side.Sell];
    }

    function spread() external view returns (uint256) {
        uint256 bid = _best[Side.Buy];
        uint256 ask = _best[Side.Sell];
        if (bid == 0 || ask == 0 || ask <= bid) return 0;
        return ask - bid;
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    function depthAt(Side side, uint256 price) external view returns (uint256) {
        return _levels[side][price].total;
    }
}
