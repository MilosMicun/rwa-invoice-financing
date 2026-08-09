# Vector 08 — Arithmetic, Rounding, Precision & DoS — Results

All probes are SAFE. No HIGH/CRITICAL findings. The protocol's arithmetic is defended by
`Math.mulDiv` (512-bit intermediate), remainder-to-junior split design, subtraction-based
comparisons, and consistent `<= availableLiquidity` / `<= lockedAssets` guards that preserve the
`accountedAssets >= lockedAssets` invariant.

## Results table

| #  | Hypothesis | Test function | Verdict | Severity | One-line result |
|----|-----------|---------------|---------|----------|-----------------|
| 1  | ZeroTranchePrincipal DoS boundary | `test_SAFE_zeroTranchePrincipal_isDoS_notFundLoss` | SAFE | LOW (griefing) | Under a permissive-but-legal config a dust invoice (advance==1) reverts `ZeroTranchePrincipal`; atomic revert, no funds/state change. |
| 1b | Default config keeps both tranches nonzero | `test_SAFE_defaultConfig_bothTranchesAlwaysNonzero` | SAFE | — | Default minInvoiceAmount 1000e18 + advanceRate 8000 makes min principal enormous; both tranches always nonzero. |
| 2  | calculateAdvance extreme faceValue | `test_SAFE_calculateAdvance_extremeFaceValue_noOverflow` | SAFE | — | `Math.mulDiv(max,9000,10000)` returns exact floor, no overflow (rate<100% ⇒ quotient<faceValue). |
| 2b | calculateAdvance == mulDiv (fuzz) | `testFuzz_SAFE_calculateAdvance_matchesMulDiv` | SAFE | — | Advance equals full-precision `mulDiv` for all fuzzed face values. |
| 3  | calculateFee rounding-to-zero | `test_SAFE_calculateFee_roundsToZero_dustPrincipal` | SAFE | INFO | Fee floors to 0 only for dust principal (1 wei); 1e18-scale principal always earns nonzero fee. LP principal never at risk. |
| 3b | Fee short-tenor boundary | `test_SAFE_calculateFee_shortTenor_boundary` | SAFE | INFO | 1 wei / 1 s ⇒ 0 fee; 1e18 / 1 day ⇒ nonzero. Zero-fee only in dust regime. |
| 4  | calculateFee overflow at max params | `test_SAFE_calculateFee_maxParams_noSpuriousOverflow` | SAFE | — | apr=5000, tenor=365d, principal=max/2: fee == mulDiv result ≈ principal/2, no spurious revert. |
| 5  | Exposure double-decrement / underflow | `test_SAFE_exposure_noDoubleDecrement_onResolvedGuard` | SAFE | — | Second settle reverts on `resolved` guard before exposure update; decrement fires exactly once ⇒ no `ExposureUnderflow`. |
| 6  | Exposure overflow on increase | `test_SAFE_exposure_overflow_unreachable_viaConcentrationCap` | SAFE | — | `checkConcentration` caps each increase at `maxExposurePerBuyer`; total exposure ≪ 2^256, overflow unreachable through the pool. |
| 7  | checkConcentration off-by-one | `test_SAFE_checkConcentration_offByOne_boundary` | SAFE | — | `E+N==max` allowed, `max+1` rejected via early-out, `E<=max-N` subtraction avoids overflow. No off-by-one. |
| 7b | checkConcentration spec (fuzz) | `testFuzz_SAFE_checkConcentration_matchesSpec` | SAFE | — | For exposure 0, allowed ⇔ `newAmount <= maxExposure` across fuzzed inputs. |
| 8  | availableLiquidity underflow | `test_SAFE_availableLiquidity_neverUnderflows_fullCycle` | SAFE | — | finance→default(0 recovery) cycle keeps `accountedAssets >= lockedAssets`; `availableLiquidity()` never underflows. |
| 9  | writeDown revert DoS in resolveDefault | `test_SAFE_resolveDefault_writeDown_noArithmeticDoS_withConcurrentLock` | SAFE | — | Concurrent locked invoice does not brick default; position unlocks its own principal before writeDown, so `loss <= availableLiquidity`. |
| 10 | Funding split conservation (fuzz) | `testFuzz_SAFE_fundingSplit_conserved` | SAFE | — | `seniorPrincipal + juniorPrincipal == principal` for all inputs (junior = remainder). |
| 11 | Fee split conservation (fuzz) | `testFuzz_SAFE_feeSplit_conserved` | SAFE | — | `seniorFee + juniorFee == fee` for all inputs (senior = remainder). |
| 12 | Governance guardrails | `test_SAFE_setRiskParams_rejectsOutOfBounds` | SAFE | — | Rejects advanceRate>9000, apr>5000, tenor>365d, any zero required field; apr==0 accepted (valid). |
| 13 | Dust across settle cycles | `test_SAFE_dust_acrossSettleCycles_noLeak` | SAFE | — | 5 finance/settle cycles: NAV grows only by fees, cash-backed each time, no dust leak to a third party. |
| 14 | First-loss waterfall integrity (fuzz) | `testFuzz_SAFE_waterfall_seniorFirstProtection` | SAFE | — | Across recovery sweep, senior loses only when junior fully wiped; `seniorLoss+juniorLoss == principal-recovery`. |

## How to run

Run from repo root (isolated build/cache and isolated test root so parallel vectors do not collide):

```bash
FOUNDRY_TEST=security-findings/08-arithmetic-rounding-dos FOUNDRY_OUT=out-v08 FOUNDRY_CACHE_PATH=cache-v08 \
  forge test --match-path 'security-findings/08-arithmetic-rounding-dos/poc/*.t.sol' -vv
```

Note: `FOUNDRY_TEST` is scoped to this vector's folder because a sibling vector's PoC
(`03-oracle-manipulation-timing`) currently fails to compile and would otherwise block the
whole-project test build. Scoping the test root builds only `_base` + this vector.

## Final observed Suite result

```
Suite result: ok. 18 passed; 0 failed; 0 skipped; finished in 78.88ms (105.63ms CPU time)
```

## What protects this / what breaks

**What protects the arithmetic:**
- `calculateAdvance` and `calculateFee` use `Math.mulDiv`
  (`src/risk/RWARiskManager.sol:179`, `:202`), giving a 512-bit intermediate so products up to
  `type(uint256).max * BPS` never overflow before division. Since `advanceRate <= 9000 < 10000`,
  the advance quotient is always `< faceValue`, so it always fits uint256 — no path reverts.
- Funding and fee splits assign the **remainder** to the junior tranche
  (`src/core/InvoiceFinancingPool.sol:281-282` and `:406-407`): `juniorPrincipal = principal -
  seniorPrincipal`, `seniorFee = fee - juniorFee`. This makes conservation exact by construction —
  no wei can be created or lost in the split.
- `checkConcentration` uses subtraction-based comparison `buyerExposure <= maxExposure - newAmount`
  with a `newAmount > maxExposure` early-out (`src/risk/RWARiskManager.sol:162-170`), so it neither
  overflows on `buyerExposure + newAmount` nor exhibits an off-by-one; exact-fit is allowed.
- `updateBuyerExposure` reverts `ExposureUnderflow` when `delta > oldExposure`
  (`src/risk/RWARiskManager.sol:256-258`); the decrement path is only reached once per position
  because `settleInvoice` / `resolveDefault` set `position.resolved = true` before the exposure
  update and guard on it at entry (`src/core/InvoiceFinancingPool.sol:376`, `:501`).
- Pool NAV mutators all keep `accountedAssets >= lockedAssets`: `lockAssets` requires
  `assets <= availableLiquidity` (`SeniorPool.sol:101`), `writeDown` requires both
  `assets <= accountedAssets` and `assets <= availableLiquidity` (`SeniorPool.sol:192-198`), and
  `unlockAssets` requires `assets <= lockedAssets` (`SeniorPool.sol:116`). Therefore
  `availableLiquidity() = accountedAssets - lockedAssets` (`SeniorPool.sol:74`) never underflows.
- `resolveDefault` unlocks a position's own principal (`unlockAssets(seniorPrincipal/juniorPrincipal)`)
  BEFORE calling `writeDown(loss)` (`InvoiceFinancingPool.sol:554-563`). Because
  `loss <= principal == amount just unlocked`, `writeDown(loss) <= availableLiquidity` always holds
  even when other invoices are concurrently locked — no arithmetic DoS.
- Governance bounds in `_setRiskParams` (`src/risk/RWARiskManager.sol:270-289`) reject zero fields
  and out-of-range advanceRate / apr / tenor; they cannot be bypassed (only `RISK_ADMIN_ROLE` can
  call, and every write goes through `_setRiskParams`).

**What "breaks" (LOW / INFO only, not exploitable HIGH/CRITICAL):**
- **ZeroTranchePrincipal DoS (LOW, griefing).** If an admin sets an atypical-but-valid config
  (e.g. `advanceRate = 1 bps`, `minInvoiceAmount = 1`), a dust invoice can pass `isEligible()`
  (advance == 1) yet revert `ZeroTranchePrincipal` at `financeInvoice`
  (`src/core/InvoiceFinancingPool.sol:284`) because `seniorPrincipal = 1 * 7000 / 10000 == 0`.
  Impact is limited to a self-inflicted, atomic revert on a 1-wei-advance invoice: no funds move,
  no state changes, no unauthorized loss/gain. Under the default config this branch is unreachable.
  Recommendation (defense-in-depth): if desired, mirror the `advance == 0` eligibility guard with a
  per-tranche minimum, or document that operators must keep `minInvoiceAmount * advanceRate / BPS`
  large enough that `principal * min(fundingShare) / BPS >= 1`.
- **Fee rounding-to-zero (INFO).** `calculateFee` floors to 0 for dust principal / sub-second tenor
  (`src/risk/RWARiskManager.sol:194-203`). At any realistic 1e18-scale principal the fee is always
  nonzero, and LP principal is never at risk — this is a negligible value-leak-to-supplier edge, not
  a vulnerability.

## Conclusion

Vector 08 is clean: no HIGH/CRITICAL arithmetic, rounding, precision, or DoS findings. The two
noted items are LOW/INFO and only manifest under dust-scale amounts or self-inflicted admin
misconfiguration. The remainder-to-junior split, `mulDiv`, subtraction-based limit checks, and the
`accountedAssets >= lockedAssets` guard family together neutralize the entire known-attack class.
