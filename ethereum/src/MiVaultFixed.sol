// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MiVaultFixed — VaultVulnerable con sus dos bugs cerrados (Taller de la Clase 7).
/// @dev Los dos cambios, el mas chico que cierra cada bug:
///      1. Reentrancy en `withdraw()`: checks-effects-interactions. El saldo se pone
///         en 0 ANTES del `call`, asi una reentrada ve saldo 0 y revierte.
///      2. Control de acceso en `setAdmin()`: solo el admin actual puede cambiarlo.
///      `deposit()` y `withdraw()` conservan la firma.
contract MiVaultFixed {
    mapping(address => uint256) private balances;

    address public admin;

    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);

    error InsufficientBalance();
    error TransferFailed();
    error NotAdmin();

    constructor() {
        admin = msg.sender;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Retira todo el saldo del que llama.
    function withdraw() external {
        // Checks
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InsufficientBalance();

        // Effects  (FIX 1: antes estaba despues del call)
        balances[msg.sender] = 0;

        // Interactions
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, amount);
    }

    /// @notice Cambia el admin.  (FIX 2: antes lo podia llamar cualquiera)
    function setAdmin(address nuevo) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = nuevo;
    }

    /// @notice Envía todo el ETH del contrato al admin.
    /// @dev Sin tocar: con `setAdmin` protegido, el riesgo que queda es de
    ///      CONFIANZA (el admin se puede llevar los depositos de todos), no un bug
    ///      explotable por un extranio. Vale mencionarlo en el hallazgo.
    function sweep() external {
        if (msg.sender != admin) revert NotAdmin();
        (bool ok, ) = admin.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}
