# Climber Reentrancy Vulnerability Analysis

## 🚨 Critical Vulnerability: Checks-Effects-Interactions Pattern Violation

### The Vulnerable Code

In [ClimberTimelock.sol](src/climber/ClimberTimelock.sol#L64-L92):

```solidity
function execute(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata dataElements,
    bytes32 salt
) external payable {
    // ... input validation ...

    bytes32 id = getOperationId(targets, values, dataElements, salt);

    // ❌ INTERACTION - External calls happen FIRST
    for (uint8 i = 0; i < targets.length; ++i) {
        targets[i].functionCallWithValue(dataElements[i], values[i]);
    }

    // ❌ CHECK - Validation happens AFTER external calls
    if (getOperationState(id) != OperationState.ReadyForExecution) {
        revert NotReadyForExecution(id);
    }

    // ❌ EFFECT - State update happens last
    operations[id].executed = true;
}
```

### Why This Is Vulnerable

**The Correct Order Should Be:**

1. ✅ **Checks** - Validate operation state
2. ✅ **Effects** - Update state
3. ✅ **Interactions** - Make external calls

**The Vulnerable Order Is:**

1. ❌ **Interactions** - Make external calls
2. ❌ **Checks** - Validate operation state
3. ❌ **Effects** - Update state

This allows reentrancy during the external calls!

---

## 🎯 Attack Scenario: Stealing All Vault Tokens

### Phase 1: Self-Scheduling Attack

**Initial State:**

- Attacker has NO roles (not PROPOSER, not ADMIN)
- Operation is NOT scheduled (state = `Unknown`)
- Vault contains 10,000,000 DVT tokens
- Vault owner is the timelock

**Attack Steps:**

1. **Attacker deploys malicious contract** with a `schedule()` callback function

2. **Attacker calls `execute()`** with an operation containing 4 calls:

   ```solidity
   targets = [timelock, timelock, timelock, attackerContract]

   Call 1: timelock.updateDelay(0)
   Call 2: timelock.grantRole(ADMIN_ROLE, attackerContract)
   Call 3: timelock.grantRole(PROPOSER_ROLE, attackerContract)
   Call 4: attackerContract.schedule() // callback!
   ```

3. **During execution loop:**
   - ✅ Call 1: Delay is updated to 0 (timelock can call itself)
   - ✅ Call 2: Attacker gets ADMIN_ROLE (timelock has ADMIN_ROLE on itself)
   - ✅ Call 3: Attacker gets PROPOSER_ROLE
   - ✅ Call 4: Attacker's contract calls back to `timelock.schedule()`
     - Now attacker HAS PROPOSER_ROLE ✓
     - Schedules the SAME operation that's currently executing
     - `readyAtTimestamp = block.timestamp + 0` (delay is 0)
     - Operation state changes: `Unknown` → `Scheduled` → `ReadyForExecution`

4. **After loop, the check runs:**

   ```solidity
   if (getOperationState(id) != OperationState.ReadyForExecution) {
       revert NotReadyForExecution(id);
   }
   ```

   - Operation IS now ReadyForExecution ✅
   - Check passes!

5. **Operation marked as executed:**
   ```solidity
   operations[id].executed = true;
   ```

**Result:** Attacker has ADMIN_ROLE and PROPOSER_ROLE with 0 delay!

---

### Phase 2: Vault Takeover

Now the attacker can exploit the vault:

6. **Deploy malicious vault implementation:**

   ```solidity
   contract MaliciousVault {
       function sweepFunds(address token, address recipient) external {
           // No access control!
           IERC20(token).transfer(recipient, IERC20(token).balanceOf(address(this)));
       }

       function proxiableUUID() external pure returns (bytes32) {
           return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
       }
   }
   ```

7. **Schedule and execute vault upgrade:**
   - Target: `vault`
   - Call: `upgradeToAndCall(maliciousVault, sweepFunds(token, attacker))`
   - Since attacker has PROPOSER_ROLE and delay=0, this executes immediately

8. **Steal all tokens:**
   - Vault's implementation is replaced
   - `sweepFunds()` is called during upgrade
   - All 10,000,000 DVT tokens transferred to attacker

---

## 🔍 Key Insights

### Why The Check Doesn't Protect

The check `getOperationState(id) != OperationState.ReadyForExecution` is meant to ensure:

- Operation was scheduled by a PROPOSER
- Sufficient delay has passed

However, by executing the check AFTER external calls:

- Attacker gains PROPOSER role during execution
- Attacker can schedule the operation during execution
- Attacker can set delay to 0 during execution

The operation "self-validates" itself!

### The Reentrancy Gap

The vulnerability exists in this specific window:

```
[Start execute] → [Grant roles] → [Schedule operation] → [CHECK PASSES] → [End execute]
                        ↓                    ↓                   ↑
                   Attacker gains      Self-schedules      Now valid!
                   PROPOSER role       the operation
```

### Why AccessControl Doesn't Help

You might notice `ClimberTimelock` inherits from `AccessControl`, which has:

- `grantRole()` - protected by `onlyRole(getRoleAdmin(role))`
- Since ADMIN_ROLE's admin is ADMIN_ROLE itself
- And timelock has ADMIN_ROLE on itself (line 28: `_grantRole(ADMIN_ROLE, address(this))`)
- The timelock CAN grant roles when calling itself!

---

## 🛡️ The Fix

Move checks BEFORE interactions:

```solidity
function execute(
    address[] calldata targets,
    uint256[] calldata values,
    bytes[] calldata dataElements,
    bytes32 salt
) external payable {
    // ... input validation ...

    bytes32 id = getOperationId(targets, values, dataElements, salt);

    // ✅ CHECK FIRST
    if (getOperationState(id) != OperationState.ReadyForExecution) {
        revert NotReadyForExecution(id);
    }

    // ✅ EFFECT SECOND
    operations[id].executed = true;

    // ✅ INTERACTION LAST
    for (uint8 i = 0; i < targets.length; ++i) {
        targets[i].functionCallWithValue(dataElements[i], values[i]);
    }
}
```

Now the operation must be properly scheduled BEFORE execution begins!

---

## 📊 Impact Summary

| Aspect                | Impact                                        |
| --------------------- | --------------------------------------------- |
| **Severity**          | 🔴 Critical                                   |
| **Attack Cost**       | Minimal (0.1 ETH for deployment)              |
| **Prerequisites**     | None (anyone can call `execute()`)            |
| **Funds at Risk**     | 10,000,000 DVT tokens (~$10M)                 |
| **Attack Complexity** | Medium (requires understanding of reentrancy) |
| **Detection**         | Difficult (single transaction attack)         |

---

## 🔗 References

- **Checks-Effects-Interactions Pattern:** https://docs.soliditylang.org/en/latest/security-considerations.html#use-the-checks-effects-interactions-pattern
- **UUPS Upgradeable Pattern:** https://eips.ethereum.org/EIPS/eip-1822
- **OpenZeppelin AccessControl:** https://docs.openzeppelin.com/contracts/4.x/api/access#AccessControl
