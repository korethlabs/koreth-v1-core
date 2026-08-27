// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC20 mock whose transfers do not deliver exactly what was requested.
/// @dev Two knobs, both applied to `transfer` and `transferFrom`:
///        - `feeBps`: burns a slice of the amount so the recipient credits LESS than requested
///          (classic fee-on-transfer token).
///        - `bonusBps`: mints a slice on top so the recipient credits MORE than requested
///          (stands in for a rebasing/donating token).
///      The sender is always debited the full `amount`, matching how real fee-on-transfer tokens
///      behave, so an integrator that trusts the requested amount ends up mis-accounting.
contract MockFeeOnTransferERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public feeBps;
    uint256 public bonusBps;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBps) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        feeBps = _feeBps;
    }

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function setBonusBps(uint256 _bonusBps) external {
        bonusBps = _bonusBps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "INSUFFICIENT_ALLOWANCE");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "INSUFFICIENT_BALANCE");
        balanceOf[from] -= amount;

        uint256 fee = (amount * feeBps) / 10_000;
        uint256 bonus = (amount * bonusBps) / 10_000;
        totalSupply = totalSupply - fee + bonus;
        balanceOf[to] += amount - fee + bonus;
    }
}
