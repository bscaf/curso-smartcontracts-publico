// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/MiVaultFixed.sol";

// ---------------------------------------------------------------------------
// Taller de la Clase 7, consigna 5: los PoCs de la consigna 2 apuntados al fix.
// Mismo setup y mismo ataque; lo que cambia es lo que se espera: que el ataque
// FALLE y que el vault conserve los fondos.
// ---------------------------------------------------------------------------

// El mismo atacante de VaultVulnerable.t.sol, tipado contra MiVaultFixed.
contract ReentrancyAttackerFixed {
    MiVaultFixed public vault;
    uint256 public stake;

    constructor(MiVaultFixed _vault) {
        vault = _vault;
    }

    function attack() external payable {
        stake = msg.value;
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    receive() external payable {
        if (address(vault).balance >= stake) {
            vault.withdraw();
        }
    }
}

contract MiVaultFixedReentrancyTest is Test {
    MiVaultFixed vault;
    address victima1 = makeAddr("victima1");
    address victima2 = makeAddr("victima2");
    address attackerOwner = makeAddr("attackerOwner");

    function setUp() public {
        vault = new MiVaultFixed();
        vm.deal(victima1, 5 ether);
        vm.deal(victima2, 5 ether);
        vm.prank(victima1);
        vault.deposit{value: 5 ether}();
        vm.prank(victima2);
        vault.deposit{value: 5 ether}();
    }

    function test_Reentrancy_NoDrenaElVault() public {
        assertEq(address(vault).balance, 10 ether);
        ReentrancyAttackerFixed attacker = new ReentrancyAttackerFixed(vault);
        vm.deal(attackerOwner, 1 ether);

        // La reentrada ve saldo 0 -> InsufficientBalance dentro del receive();
        // el call del withdraw externo devuelve false -> TransferFailed, y se
        // deshace toda la tx (incluido el deposito del atacante).
        vm.prank(attackerOwner);
        vm.expectRevert(MiVaultFixed.TransferFailed.selector);
        attacker.attack{value: 1 ether}();

        assertEq(address(vault).balance, 10 ether);   // el vault conserva todo
        assertEq(address(attacker).balance, 0);
        assertEq(attackerOwner.balance, 1 ether);     // al atacante le vuelve su ETH
        assertEq(vault.balanceOf(victima1), 5 ether);
        assertEq(vault.balanceOf(victima2), 5 ether);
    }

    /// Que el fix no rompio el caso legitimo: las victimas siguen pudiendo retirar.
    function test_Withdraw_LegitimoSigueAndando() public {
        vm.prank(victima1);
        vault.withdraw();
        assertEq(victima1.balance, 5 ether);
        assertEq(vault.balanceOf(victima1), 0);
        assertEq(address(vault).balance, 5 ether);
    }
}

contract MiVaultFixedAccessControlTest is Test {
    MiVaultFixed vault;
    address deployer = makeAddr("deployer");
    address victima = makeAddr("victima");
    address atacante = makeAddr("atacante");

    function setUp() public {
        vm.prank(deployer);
        vault = new MiVaultFixed();
        vm.deal(victima, 8 ether);
        vm.prank(victima);
        vault.deposit{value: 8 ether}();
    }

    function test_AccessControl_ExtranioNoSeQuedaConLosFondos() public {
        vm.prank(atacante);
        vm.expectRevert(MiVaultFixed.NotAdmin.selector);
        vault.setAdmin(atacante);

        vm.prank(atacante);
        vm.expectRevert(MiVaultFixed.NotAdmin.selector);
        vault.sweep();

        assertEq(vault.admin(), deployer);
        assertEq(atacante.balance, 0);
        assertEq(address(vault).balance, 8 ether);
    }

    /// El admin legitimo sigue pudiendo traspasar el rol.
    function test_SetAdmin_ElAdminPuedeTraspasar() public {
        vm.prank(deployer);
        vault.setAdmin(atacante);
        assertEq(vault.admin(), atacante);
    }
}
