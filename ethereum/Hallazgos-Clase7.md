# Taller de la Clase 7 — Hallazgos sobre `VaultVulnerable.sol`

Salidas reales de las herramientas en `salidas/clase7/`. Todo se corre desde `ethereum/`.

## Triage de Slither (consigna 1)

`slither src/VaultVulnerable.sol` → 5 resultados:

| Detector | Dónde | ¿Real o ruido? |
|---|---|---|
| `reentrancy-eth` (High) | `withdraw()` | **Real.** El `call` va antes de `balances[msg.sender] = 0`: es el hallazgo 1. |
| `reentrancy-events` (Low) | `withdraw()` | Ruido. El evento se emite después del `call`; sólo afecta el orden de los logs. Sigue apareciendo en el fix. |
| `missing-zero-check` (Low) | `setAdmin(nuevo)` | Ruido en sí mismo (poner `admin = 0` sólo bloquea `sweep`), pero **está al lado del bug real** y no lo nombra. |
| `low-level-calls` (Info) | `withdraw()`, `sweep()` | Ruido. `call` es la forma recomendada de mandar ETH. |

`slither src/VaultVulnerable.sol --print vars-and-auth` → la fila que delata el bug que el triage no
encontró:

```
| setAdmin    | ['admin']               | []                       |
```

`setAdmin` escribe `admin` con **ninguna** condición sobre `msg.sender`, y `admin` es justo lo que
`sweep` usa como control de acceso (`['msg.sender != admin']`). Ningún detector lo reporta: es una
propiedad de la intención ("sólo el admin cambia el admin"), no un patrón sintáctico.

---

## [HIGH] Reentrancy en `withdraw()` permite drenar el vault

**Ubicación:** `src/VaultVulnerable.sol`, `withdraw()`, líneas 29–39
**Descripción:** `withdraw()` manda el ETH con `msg.sender.call{value: amount}("")` **antes** de
poner el saldo en 0. Un contrato que recibe ese ETH vuelve a llamar a `withdraw()` desde su
`receive()`, ve su saldo todavía intacto y vuelve a cobrar, hasta vaciar el vault.
**Impacto:** con 1 ETH propio el atacante se lleva los 10 ETH de las víctimas (11 retiros: 1 + 10
reentradas, en una sola transacción). El libro contable sigue diciendo que las víctimas tienen 5 ETH
cada una, pero ya no pueden retirar: `withdraw()` revierte con `TransferFailed`.
**Prueba de concepto:** `test/VaultVulnerable.t.sol::test_Reentrancy_DrenaElVault`
(`forge test --match-test test_Reentrancy_DrenaElVault -vvvv`). También lo encuentran el fuzzer
(`invariant_solvency_DEMO`, con el `assertGe` descomentado: secuencia de 2 llamadas,
`legitDeposit` y `runAttack`) y halmos (`halmos --contract VaultVulnerableHalmos`: `FAIL` con
contraejemplo).
**Recomendación:** checks-effects-interactions: `balances[msg.sender] = 0` antes del `call`.
Opcionalmente, además, un `nonReentrant` (`ReentrancyGuard` de OpenZeppelin).
**Estado:** corregido en `src/MiVaultFixed.sol`. Lo verifican
`test/MiVaultFixed.t.sol::test_Reentrancy_NoDrenaElVault` (el ataque revierte y el vault conserva
los 10 ETH) y `halmos --contract MiVaultFixedHalmos` (`PASS`, también con `--invariant-depth 4`).
Slither sobre el fix ya no reporta `reentrancy-eth`.

## [HIGH] `setAdmin()` sin control de acceso: cualquiera se queda con todos los fondos

**Ubicación:** `src/VaultVulnerable.sol`, `setAdmin()`, líneas 41–44 (y `sweep()`, 46–51)
**Descripción:** `setAdmin()` no verifica quién llama. Cualquiera se nombra admin y después llama a
`sweep()`, que manda **todo** el ETH del contrato al admin.
**Impacto:** el atacante se lleva el 100 % del vault (8 ETH en el PoC) con dos transacciones desde
una EOA, sin contrato atacante y sin capital propio.
**Prueba de concepto:** `test/VaultVulnerable.t.sol::test_AccessControl_ExtranioSeQuedaConLosFondos`.
**Recomendación:** `if (msg.sender != admin) revert NotAdmin();` en `setAdmin()`. Para un traspaso
más seguro, el patrón de dos pasos (`Ownable2Step`).
**Estado:** corregido en `src/MiVaultFixed.sol`. Lo verifica
`test/MiVaultFixed.t.sol::test_AccessControl_ExtranioNoSeQuedaConLosFondos`.
Riesgo residual: `sweep()` le sigue dando al admin los depósitos de todos (riesgo de confianza, no
explotable por un extraño).

---

## Discusión (consigna 5)

**¿El arreglo sigue protegiendo si alguien reordena `withdraw()` o agrega otra función que manda
ETH?** No. CEI es una **disciplina**, no un mecanismo: protege mientras alguien la respete en cada
función. Si alguien vuelve a poner el `= 0` después del `call`, el bug vuelve. Y si se agrega una
función que manda ETH antes de actualizar estado, sobre todo si comparte estado con `withdraw()`,
aparece una reentrancy cross-function. Un `nonReentrant` en **todas** las funciones que tocan
`balances` lo cierra aunque alguien se equivoque con el orden, a cambio de gas (un `SSTORE` de ida
y otro de vuelta por llamada, mucho menos con `ReentrancyGuardTransient`, que usa `TSTORE`) y de
prohibir reentradas legítimas. Las herramientas lo detectarían: Slither volvería a marcar
`reentrancy-eth` y el invariante de halmos y del fuzzer volvería a fallar.

**`--invariant-depth 1` sobre el vulnerable da `PASS`.** Con una sola llamada no se rompe nada: el
ataque necesita que **antes** haya ETH ajeno en el vault (un `legitDeposit`). Con un único
`runAttack`, la reentrada intenta cobrar dos veces el `stake` de un vault que tiene uno solo: el
`call` falla, el camino revierte y halmos lo descarta. `PASS` quiere decir "ninguna secuencia de
largo ≤ 1 rompe la solvencia", no "es seguro".
