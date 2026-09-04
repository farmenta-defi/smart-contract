# Farmenta contracts — common tasks.
# Fork targets need ROBINHOOD_RPC_URL (see .env.example); unit targets need no network.

-include .env
export

.PHONY: install build clean fmt fmt-check test test-fork test-all test-deep addresses gas

install:
	forge install

build:
	forge build

clean:
	forge clean

fmt:
	forge fmt

fmt-check:
	forge fmt --check

## Unit tests only — no network, no RPC key. This is the fast CI lane.
test:
	FOUNDRY_PROFILE=lite forge test --no-match-path "test/fork/**"

## Fork tests against the pinned block.
test-fork:
	forge test --match-path "test/fork/**"

test-all:
	forge test

## Long fuzz/invariant campaigns — PRs to main and the nightly run.
test-deep:
	FOUNDRY_PROFILE=deep forge test

## Verify every address in src/constants/RobinhoodChain.sol against live chain state.
addresses:
	forge test --match-contract AddressesForkTest -vv

gas:
	forge test --gas-report
