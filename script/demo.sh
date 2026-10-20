#!/usr/bin/env bash
# Local demo: fresh anvil, deploy with the seeded ladder, then cross the book.
set -euo pipefail

RPC=http://127.0.0.1:8545
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADDR0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADDR1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

anvil --silent --port 8545 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 1

OUT=$(forge script script/Deploy.s.sol --rpc-url $RPC --broadcast 2>/dev/null)
echo "$OUT" | grep -E "BASE|QUSD|BOOK|seeded" || true
BASE=$(echo "$OUT" | awk '/BASE/{print $2}')
QUSD=$(echo "$OUT" | awk '/QUSD/{print $2}')
BOOK=$(echo "$OUT" | awk '/BOOK/{print $2}')

bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url $RPC; }

echo
echo "after seeding (bids 2.0 x50, 2.2 x40 from account0; asks 2.6 x45, 2.8 x60 from account1)"
echo "  best bid: $(cast call $BOOK 'bestBid()(uint256)' --rpc-url $RPC)"
echo "  best ask: $(cast call $BOOK 'bestAsk()(uint256)' --rpc-url $RPC)"
echo "  account0 BASE: $(bal $BASE $ADDR0)"
echo "  account1 QUSD: $(bal $QUSD $ADDR1)"

echo
echo "account0 buys 20 BASE at 2.6, crossing account1's ask..."
cast send $BOOK "placeBuy(uint256,uint256)" 2600000000000000000 20000000000000000000 \
  --private-key $KEY0 --rpc-url $RPC > /dev/null

echo "  account0 BASE: $(bal $BASE $ADDR0)  (gained 20)"
echo "  account1 QUSD: $(bal $QUSD $ADDR1)  (gained 52, that is 20 at 2.6)"
echo "  ask depth left at 2.6: $(cast call $BOOK 'depthAt(uint8,uint256)(uint256)' 1 2600000000000000000 --rpc-url $RPC)"
echo "  best ask still: $(cast call $BOOK 'bestAsk()(uint256)' --rpc-url $RPC)"
