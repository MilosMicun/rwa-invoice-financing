// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ReentrantToken
/// @notice ERC20 that invokes an attacker-controlled hook on every token movement,
///         simulating an ERC777/callback-style asset. Used to probe reentrancy in the
///         InvoiceFinancingPool settle/resolve/deposit/withdraw flows.
/// @dev The hook fires INSIDE _update (i.e. mid-transfer), before the outer protocol call
///      has finished, which is exactly the ERC777 `tokensReceived` reentrancy surface.
contract ReentrantToken is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookArmed;
    bool private _inHook;
    uint256 public hookFireCount;

    constructor() ERC20("Reentrant Asset", "REEN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm a single reentrant call to `target` with `data` on the next token movement.
    function armHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        hookArmed = true;
    }

    function disarm() external {
        hookArmed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (hookArmed && !_inHook && hookTarget != address(0)) {
            _inHook = true;
            hookArmed = false; // fire once per arming to avoid infinite loops
            hookFireCount++;
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            _inHook = false;
            // Bubble up revert reason so PoCs can assert on the reentrant call outcome.
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @title FeeOnTransferToken
/// @notice ERC20 that burns a fee on every transfer, so the recipient receives less than `amount`.
///         Used to probe accounting assumptions that credited/received == amount.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) ERC20("Fee Asset", "FEE") {
        FEE_BPS = feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Minting/burning (from==0 or to==0) are not taxed; only real transfers are.
        if (from != address(0) && to != address(0) && FEE_BPS > 0) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0), fee); // burn fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
