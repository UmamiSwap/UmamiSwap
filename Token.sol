//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20Fees.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20VotesComp.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/*
    UmamiSwap
    - Website: https://umamiswap.net/
    - Telegram: https://t.me/umamiswap
*/

contract Umami is ERC20Fees {
    bytes32 public constant BOUNCER_ROLE = keccak256("BOUNCER_ROLE");
    mapping(address => bool) public blacklisted;

    // Events
    event Blacklisted(address indexed addr, bool status);

    constructor(address _router, address _marketingWallet, address _devWallet)
        ERC20("UmamiSwap", "UMAMI")
        ERC20Permit("UmamiSwap")
        ERC20Fees(_router, _marketingWallet, _devWallet)
    {
        // Initially make deployer superadmin
        _grantRole(bytes32(0), msg.sender);
        _grantRole(FEE_ROLE, msg.sender);
        _grantRole(BOUNCER_ROLE, msg.sender);

        uint256 supply = 100_000_000 * (10**decimals());
        _mint(msg.sender, supply);
        tokensCollectingRewards = supply;

        // Set the sell buffer to 0.5% of the supply
        sellBuffer = supply / 200;
    }

    function addToBlacklist(address addr) public onlyRole(BOUNCER_ROLE) {
        require(addr != address(this), "BLACKLIST: CONTRACT_SELF");
        require(addr != _msgSender(), "BLACKLIST: SELF");
        require(!isPair[addr], "BLACKLIST: PAIR");

        // If the blacklisted user is a user who can blacklist we remove those privilages
        if (hasRole(BOUNCER_ROLE, addr)) {
            _revokeRole(BOUNCER_ROLE, addr);
        }

        blacklisted[addr] = true;
        emit Blacklisted(addr, true);
    }

    function removeFromBlacklist(address addr) public onlyRole(BOUNCER_ROLE) {
        require(blacklisted[addr], "BLACKLIST: ALREADY_BLACKLISTED");

        blacklisted[addr] = false;
        emit Blacklisted(addr, false);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // Blacklist only works when the safemode is disabled
        // Only stop the transfer if the recipient is blacklisted (which can not be a pair address)
        require(safemode || !blacklisted[to], "BLACKLIST: BLACKLISTED");
        super._beforeTokenTransfer(from, to, amount);
    }
}
