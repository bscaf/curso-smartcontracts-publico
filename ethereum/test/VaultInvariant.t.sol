// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/Vault.sol";

// ---------------------------------------------------------------------------
// Clase 6 — invariant testing sobre el Vault de la Clase 3 (slides 40–41)
// ---------------------------------------------------------------------------
//     forge test --match-contract VaultInvariantTest -vv
//
// Foundry llama al handler con secuencias aleatorias de deposit / withdraw /
// withdrawAll y, despues de cada llamada, chequea los invariant_*.

contract VaultHandler is Test {
    Vault public vault;
    address[] public actors;
    mapping(address => uint256) public depositedBy;
    uint256 public totalTracked;   // lo que el handler cree que hay en el Vault

    constructor(Vault _vault) {
        vault = _vault;
        for (uint256 i = 0; i < 3; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            vm.deal(a, 100 ether);
            actors.push(a);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        if (actor.balance == 0) return;
        amount = bound(amount, 1, actor.balance);
        vm.prank(actor);
        vault.deposit{value: amount}();
        depositedBy[actor] += amount;
        totalTracked += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        // Sin saldo, bound(amount, 1, 0) revierte: es uno de los "reverts" que
        // muestra Foundry, y no es una falla (fail_on_revert = false por defecto).
        amount = bound(amount, 1, vault.balanceOf(actor));
        vm.prank(actor);
        vault.withdraw(amount);
        depositedBy[actor] -= amount;
        totalTracked -= amount;
    }

    function withdrawAll(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 saldo = vault.balanceOf(actor);
        vm.prank(actor);
        vault.withdrawAll();   // revierte si saldo == 0: otro revert esperado
        depositedBy[actor] -= saldo;
        totalTracked -= saldo;
    }
}

contract VaultInvariantTest is Test {
    Vault vault;
    VaultHandler handler;

    function setUp() public {
        vault = new Vault();
        handler = new VaultHandler(vault);
        targetContract(address(handler));   // Foundry llama al handler, no al Vault
    }

    /// Solvencia: lo que el Vault tiene de verdad == lo que el handler conto.
    function invariant_solvency() public view {
        assertEq(address(vault).balance, handler.totalTracked());
    }

    /// Contabilidad: el saldo interno de cada actor == lo que el handler le asigno.
    function invariant_balancesCuadran() public view {
        uint256 suma;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address a = handler.actors(i);
            assertEq(vault.balanceOf(a), handler.depositedBy(a));
            suma += vault.balanceOf(a);
        }
        assertEq(suma, address(vault).balance);
    }
}
