(use-trait sip010-trait .trait-sip-010.sip-010-trait)

(define-constant err-unauthorised (err u1000))
(define-constant err-paused (err u1001))
(define-constant err-peg-in-address-not-found (err u1002))
(define-constant err-invalid-amount (err u1003))
(define-constant err-token-mismatch (err u1004))
(define-constant err-invalid-tx (err u1005))
(define-constant err-already-sent (err u1006))
(define-constant err-address-mismatch (err u1007))
(define-constant err-request-already-revoked (err u1008))
(define-constant err-request-already-finalized (err u1009))
(define-constant err-revoke-grace-period (err u1010))
(define-constant err-request-already-claimed (err u1011))
(define-constant err-invalid-input (err u1012))
(define-constant err-tx-mined-before-request (err u1013))

(define-constant MAX_UINT u340282366920938463463374607431768211455)
(define-constant ONE_8 u100000000)

(define-data-var contract-owner principal tx-sender)
(define-data-var fee-address principal tx-sender)

;; governance functions

(define-public (set-contract-owner (new-contract-owner principal))
	(begin
		(try! (is-contract-owner))
		(ok (var-set contract-owner new-contract-owner))))

(define-public (set-fee-address (new-fee-address principal))
	(begin
		(try! (is-contract-owner))
		(ok (var-set fee-address new-fee-address))))

;; read-only functions

(define-read-only (get-request-revoke-grace-period)
	(contract-call? .brc20-bridge-registry-v1-02 get-request-revoke-grace-period))

(define-read-only (get-request-claim-grace-period)
	(contract-call? .brc20-bridge-registry-v1-02 get-request-claim-grace-period))

(define-read-only (is-peg-in-address-approved (address (buff 128)))
	(contract-call? .brc20-bridge-registry-v1-02 is-peg-in-address-approved address))

(define-read-only (get-token-to-tick-or-fail (token principal))
	(contract-call? .brc20-bridge-registry-v1-02 get-token-to-tick-or-fail token))

(define-read-only (get-token-details-or-fail (tick (string-utf8 4)))
	(contract-call? .brc20-bridge-registry-v1-02 get-token-details-or-fail tick))

(define-read-only (get-token-details-or-fail-by-address (token principal))
	(contract-call? .brc20-bridge-registry-v1-02 get-token-details-or-fail-by-address token))

(define-read-only (is-approved-token (tick (string-utf8 4)))
	(contract-call? .brc20-bridge-registry-v1-02 is-approved-token tick))

(define-read-only (get-request-or-fail (request-id uint))
	(contract-call? .brc20-bridge-registry-v1-02 get-request-or-fail request-id))

(define-read-only (create-order-or-fail (order { user: principal, dest: uint }))
	(ok (unwrap! (to-consensus-buff? order) err-invalid-input)))

(define-read-only (decode-order-or-fail (order-script (buff 128)))
	(ok (unwrap! (from-consensus-buff? { user: principal, dest: uint } (unwrap-panic (slice? order-script u2 (len order-script)))) err-invalid-input)))

(define-read-only (get-peg-in-sent-or-default (bitcoin-tx (buff 8192)) (output uint) (offset uint))
	(contract-call? .brc20-bridge-registry-v1-02 get-peg-in-sent-or-default bitcoin-tx output offset))

(define-read-only (get-fee-address)
	(var-get fee-address))

(define-read-only (extract-tx-ins-outs (tx (buff 8192)))
	(if (try! (contract-call? .clarity-bitcoin-v1-05 is-segwit-tx tx))
		(let
			(
				(parsed-tx (unwrap! (contract-call? .clarity-bitcoin-v1-05 parse-wtx tx) err-invalid-tx))
			)
			(ok { ins: (get ins parsed-tx), outs: (get outs parsed-tx) })
		)
		(let
			(
				(parsed-tx (unwrap! (contract-call? .clarity-bitcoin-v1-05 parse-tx tx) err-invalid-tx))
			)
			(ok { ins: (get ins parsed-tx), outs: (get outs parsed-tx) })
		)
	)
)

;; validate-tx
;;
;; given the inputs,
;; (1) confirm the tx is indexed (by Bitcoin Oracle),
;; (2) the tx has not yet been processed,
;; (3) the peg-in address in the tx is one of the approved / correct addresses to receive BRC20 tokens
(define-read-only (validate-tx (tx (buff 8192)) (output-idx uint) (offset-idx uint) (order-idx uint) (token principal))
	(let (
			(tx-idxed (try! (contract-call? .oracle-v1-06 get-bitcoin-tx-indexed-or-fail tx output-idx offset-idx)))
			(parsed-tx (try! (extract-tx-ins-outs tx)))
			(order-script (get scriptPubKey (unwrap-panic (element-at? (get outs parsed-tx) order-idx))))
			(order-details (try! (decode-order-or-fail order-script)))
			(token-details (try! (get-token-details-or-fail (get tick tx-idxed))))
			(amt-in-fixed (decimals-to-fixed (get amt tx-idxed) (contract-call? .oracle-v1-06 get-tick-decimals-or-default (get tick tx-idxed))))
			(fee (mul-down amt-in-fixed (get peg-in-fee token-details)))
			(amt-net (- amt-in-fixed fee)))
		(asserts! (is-eq token (get token token-details)) err-token-mismatch)
		(asserts! (not (get-peg-in-sent-or-default tx output-idx offset-idx)) err-already-sent)
		(asserts! (is-peg-in-address-approved (get to tx-idxed)) err-peg-in-address-not-found)

		(ok { order-details: order-details, fee: fee, amt-net: amt-net, tx-idxed: tx-idxed, token-details: token-details })
	)
)

;; public functions

;; pegs in `tick` of `amt` (net of fee) from Bitcoin to Stacks.
;; the relevant tx must (1) have been indexed and (2) include OP_RETURN with Stacks address (see `create-order-or-fail`)
;;
;; tx => bitcoin tx hash of peg-in transfer
;; order-idx => index of OP_RETURN
;; token-trait => trait of pegged-in token

(define-public (finalize-peg-in-on-index
	(tx { bitcoin-tx: (buff 8192), output: uint, offset: uint, tick: (string-utf8 4), amt: uint, from: (buff 128), to: (buff 128), from-bal: uint, to-bal: uint, decimals: uint })
	(block { header: (buff 80), height: uint })
	(proof { tx-index: uint, hashes: (list 14 (buff 32)), tree-depth: uint })
	(signature-packs (list 10 { signer: principal, tx-hash: (buff 32), signature: (buff 65) }))
	(order-idx uint) (token-trait <sip010-trait>))
	(begin
		(try! (index-tx tx block proof signature-packs))
		(finalize-peg-in (get bitcoin-tx tx) (get output tx) (get offset tx) order-idx token-trait)))

(define-public (finalize-peg-in (tx (buff 8192)) (output-idx uint) (offset-idx uint) (order-idx uint) (token-trait <sip010-trait>))
	(let (
			(token (contract-of token-trait))
			(validation-data (try! (validate-tx tx output-idx offset-idx order-idx token)))
			(tx-idxed (get tx-idxed validation-data))
			(order-details (get order-details validation-data))
			(order-address (get user order-details))
			(dest (get dest order-details))
			(token-details (get token-details validation-data))
			(fee (get fee validation-data))
			(amt-net (get amt-net validation-data)))
		(asserts! (not (get peg-in-paused token-details)) err-paused)

		(as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-peg-in-sent { tx: tx, output: output-idx, offset: offset-idx } true)))
		(and (> fee u0) (as-contract (try! (contract-call? token-trait mint-fixed fee (var-get fee-address)))))

		;; map cannot hold traits, so the below have to be hard-coded.
		;; mint to order-address if either dest == 0 or order-address is not registered with b20, or token is not registered with b20
		(if (or (is-eq dest u0) (is-err (contract-call? .stxdx-registry get-user-id-or-fail order-address)) (is-none (contract-call? .stxdx-registry get-asset-id token)))
			(begin
				(and (> amt-net u0) (as-contract (try! (contract-call? token-trait mint-fixed amt-net order-address))))
				(print (merge tx-idxed { type: "peg-in", order-address: order-address, fee: fee, amt-net: amt-net, dest: u0, bitcoin-tx: tx, output-idx: output-idx, offset-idx: offset-idx, order-idx: order-idx }))
			)
			(begin
				(and (> amt-net u0) (as-contract (try! (contract-call? token-trait mint-fixed amt-net tx-sender))))
				(and (> amt-net u0) (as-contract (try! (contract-call? .stxdx-wallet-zero transfer-in
					amt-net
					(try! (contract-call? .stxdx-registry get-user-id-or-fail order-address))  ;; user-id
					(unwrap-panic (contract-call? .stxdx-registry get-asset-id token)) ;; asset-id
					token-trait))))
				(print (merge tx-idxed { type: "peg-in", order-address: order-address, fee: fee, amt-net: amt-net, dest: u1, bitcoin-tx: tx, output-idx: output-idx, offset-idx: offset-idx, order-idx: order-idx }))
			)
		)
		(ok true)))

;; request peg-out of `tick` of `amount` (net of fee) to `peg-out-address`
;; request escrows the relevant pegged-in token and gas-fee token to the contract until the request is either finalized or revoked.
;;
;; token-trait => the trait of pegged-in token
(define-public (request-peg-out (tick (string-utf8 4)) (amount uint) (peg-out-address (buff 128)) (token-trait <sip010-trait>))
	(let (
			(token (contract-of token-trait))
			(token-details (try! (get-token-details-or-fail tick)))
			(fee (mul-down amount (get peg-out-fee token-details)))
			(amount-net (- amount fee))
			(gas-fee (get peg-out-gas-fee token-details))
			(request-details { requested-by: tx-sender, peg-out-address: peg-out-address, tick: tick, amount-net: amount-net, fee: fee, gas-fee: gas-fee, claimed: u0, claimed-by: tx-sender, fulfilled-by: 0x, revoked: false, finalized: false, requested-at: block-height, requested-at-burn-height: burn-block-height })
			(request-id (as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-request u0 request-details)))))
		(asserts! (not (get peg-out-paused token-details)) err-paused)
		(asserts! (is-eq token (get token token-details)) err-token-mismatch)
		(asserts! (> amount u0) err-invalid-amount)

		(try! (contract-call? token-trait transfer-fixed amount tx-sender (as-contract tx-sender) none))
		(and (> gas-fee u0) (try! (contract-call? .token-susdt transfer-fixed gas-fee tx-sender (as-contract tx-sender) none)))

		(print (merge request-details { type: "request-peg-out", request-id: request-id }))
		(ok true)))

;; claim peg-out request, so that the claimer can safely process the peg-out (within the grace period)
;;
(define-public (claim-peg-out (request-id uint) (fulfilled-by (buff 128)))
	(let (
			(claimer tx-sender)
			(request-details (try! (get-request-or-fail request-id)))
			(token-details (try! (get-token-details-or-fail (get tick request-details)))))
		(asserts! (not (get peg-out-paused token-details)) err-paused)
		(asserts! (< (get claimed request-details) block-height) err-request-already-claimed)
		(asserts! (not (get revoked request-details)) err-request-already-revoked)
		(asserts! (not (get finalized request-details)) err-request-already-finalized)

		(as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-request request-id (merge request-details { claimed: (+ block-height (get-request-claim-grace-period)), claimed-by: claimer, fulfilled-by: fulfilled-by }))))

		(print (merge request-details { type: "claim-peg-out", request-id: request-id, claimed: (+ block-height (get-request-claim-grace-period)), claimed-by: claimer, fulfilled-by: fulfilled-by }))
		(ok true)
	)
)

;; finalize peg-out request
;; finalize `request-id` with `tx`
;; pays the fee to `fee-address` and burn the relevant pegged-in tokens.
;;
;; peg-out finalization can be done by either a peg-in address or a non-peg-in (i.e. 3rd party) address
;; if the latter, then the overall peg-in balance does not change.
;; the claimer sends non-pegged-in BRC20 tokens to the peg-out requester and receives the pegged-in BRC20 tokens (along with gas-fee)
;; if the former, then the overall peg-in balance decreases.
;; the relevant BRC20 tokens are burnt (with fees paid to `fee-address`)
(define-public (finalize-peg-out-on-index (request-id uint)
	(tx { bitcoin-tx: (buff 8192), output: uint, offset: uint, tick: (string-utf8 4), amt: uint, from: (buff 128), to: (buff 128), from-bal: uint, to-bal: uint, decimals: uint })
	(block { header: (buff 80), height: uint })
	(proof { tx-index: uint, hashes: (list 14 (buff 32)), tree-depth: uint })
	(signature-packs (list 10 { signer: principal, tx-hash: (buff 32), signature: (buff 65) }))
	(token-trait <sip010-trait>))
	(begin 
		(try! (index-tx tx block proof signature-packs))
		(finalize-peg-out request-id (get bitcoin-tx tx) (get output tx) (get offset tx) token-trait)))

(define-public (finalize-peg-out (request-id uint) (tx (buff 8192)) (output-idx uint) (offset-idx uint) (token-trait <sip010-trait>))
	(let (
			(token (contract-of token-trait))
			(request-details (try! (get-request-or-fail request-id)))
			(token-details (try! (get-token-details-or-fail (get tick request-details))))
			(tx-idxed (try! (contract-call? .oracle-v1-06 get-bitcoin-tx-indexed-or-fail tx output-idx offset-idx)))
			(tx-mined-height (try! (contract-call? .oracle-v1-06 get-bitcoin-tx-mined-or-fail tx)))
			(amount-in-fixed (decimals-to-fixed (get amt tx-idxed) (contract-call? .oracle-v1-06 get-tick-decimals-or-default (get tick tx-idxed))))
			(fulfilled-by (get from tx-idxed))
			(is-fulfilled-by-peg-in (is-peg-in-address-approved fulfilled-by))
			)
		(asserts! (not (get peg-out-paused token-details)) err-paused)
		(asserts! (is-eq token (get token token-details)) err-token-mismatch)
		(asserts! (is-eq (get tick request-details) (get tick tx-idxed)) err-token-mismatch)
		(asserts! (is-eq (get amount-net request-details) amount-in-fixed) err-invalid-amount)
		(asserts! (is-eq (get peg-out-address request-details) (get to tx-idxed)) err-address-mismatch)
		(asserts! (is-eq (get fulfilled-by request-details) fulfilled-by) err-address-mismatch)
		(asserts! (< (get requested-at-burn-height request-details) tx-mined-height) err-tx-mined-before-request)
		(asserts! (not (get-peg-in-sent-or-default tx output-idx offset-idx)) err-already-sent)
		(asserts! (not (get revoked request-details)) err-request-already-revoked)
		(asserts! (not (get finalized request-details)) err-request-already-finalized)

		(as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-peg-in-sent { tx: tx, output: output-idx, offset: offset-idx } true)))
		(as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-request request-id (merge request-details { finalized: true }))))

		(and (> (get fee request-details) u0) (as-contract (try! (contract-call? token-trait transfer-fixed (get fee request-details) tx-sender (var-get fee-address) none))))
		(and (> (get gas-fee request-details) u0) (as-contract (try! (contract-call? .token-susdt transfer-fixed (get gas-fee request-details) tx-sender (if is-fulfilled-by-peg-in (var-get fee-address) (get claimed-by request-details)) none))))

		(if is-fulfilled-by-peg-in
			(as-contract (try! (contract-call? token-trait burn-fixed (get amount-net request-details) tx-sender)))
			(as-contract (try! (contract-call? token-trait transfer-fixed (get amount-net request-details) tx-sender (get claimed-by request-details) none)))
		)

		(print { type: "finalize-peg-out", request-id: request-id, tx: tx })
		(ok true)))

;; revoke peg-out request
;; only after `request-revoke-grace-period` passed
;; returns fee and pegged-in tokens to the requester.
(define-public (revoke-peg-out (request-id uint) (token-trait <sip010-trait>))
	(let (
			(token (contract-of token-trait))
			(request-details (try! (get-request-or-fail request-id)))
			(token-details (try! (get-token-details-or-fail (get tick request-details)))))
		(asserts! (is-eq token (get token token-details)) err-token-mismatch)
		(asserts! (> block-height (+ (get requested-at request-details) (get-request-revoke-grace-period))) err-revoke-grace-period)
		(asserts! (< (get claimed request-details) block-height) err-request-already-claimed)
		(asserts! (not (get revoked request-details)) err-request-already-revoked)
		(asserts! (not (get finalized request-details)) err-request-already-finalized)

		(as-contract (try! (contract-call? .brc20-bridge-registry-v1-02 set-request request-id (merge request-details { revoked: true }))))

		(and (> (get fee request-details) u0) (as-contract (try! (contract-call? token-trait transfer-fixed (get fee request-details) tx-sender (get requested-by request-details) none))))
		(and (> (get gas-fee request-details) u0) (as-contract (try! (contract-call? .token-susdt transfer-fixed (get gas-fee request-details) tx-sender (get requested-by request-details) none))))
		(as-contract (try! (contract-call? token-trait transfer-fixed (get amount-net request-details) tx-sender (get requested-by request-details) none)))

		(print { type: "revoke-peg-out", request-id: request-id })
		(ok true)))

;; internal functions

(define-private (index-tx
	(tx { bitcoin-tx: (buff 8192), output: uint, offset: uint, tick: (string-utf8 4), amt: uint, from: (buff 128), to: (buff 128), from-bal: uint, to-bal: uint, decimals: uint })
	(block { header: (buff 80), height: uint })
	(proof { tx-index: uint, hashes: (list 14 (buff 32)), tree-depth: uint })
	(signature-packs (list 10 { signer: principal, tx-hash: (buff 32), signature: (buff 65) })))
	(begin 
		(and 
			(not (is-ok (contract-call? .oracle-v1-06 get-bitcoin-tx-indexed-or-fail (get bitcoin-tx tx) (get output tx) (get offset tx))))
			(as-contract (try! (contract-call? .oracle-v1-06 index-tx-many (list { tx: tx, block: block, proof: proof, signature-packs: signature-packs })))))
		(print { type: "indexed-tx", tx: tx, block: block, proof: proof, signature-packs: signature-packs })
		(ok true)))

(define-private (is-contract-owner)
	(ok (asserts! (is-eq (var-get contract-owner) tx-sender) err-unauthorised)))

(define-private (min (a uint) (b uint))
	(if (< a b) a b))

(define-private (mul-down (a uint) (b uint))
	(/ (* a b) ONE_8))

(define-private (div-down (a uint) (b uint))
	(if (is-eq a u0)
		u0
		(/ (* a ONE_8) b)))

(define-private (decimals-to-fixed (amount uint) (decimals uint))
	(/ (* amount ONE_8) (pow u10 decimals)))
