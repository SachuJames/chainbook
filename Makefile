FORGE ?= forge

.PHONY: test snapshot demo deploy-sepolia

test:
	$(FORGE) test

snapshot:
	$(FORGE) snapshot

# fresh anvil, seeded book, one crossing trade: see script/demo.sh
demo:
	bash script/demo.sh

# Needs SEPOLIA_RPC_URL and DEPLOYER_KEY in the environment, and a funded
# deployer. After it runs, verify with:
#   forge verify-contract <BOOK_ADDRESS> src/ChainBook.sol:ChainBook \
#     --chain sepolia --constructor-args $(cast abi-encode "constructor(address,address)" <BASE> <QUSD>)
deploy-sepolia:
	PRIVATE_KEY=$(DEPLOYER_KEY) $(FORGE) script script/Deploy.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) --broadcast
