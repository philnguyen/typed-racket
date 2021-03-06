#lang racket/base

(require "../utils/utils.rkt"
         racket/match racket/list
         (except-in (types abbrev union utils prop-ops tc-result)
                    -> ->* one-of/c)
         (rep type-rep prop-rep object-rep values-rep rep-utils)
         (typecheck tc-subst check-below)
         (contract-req))

(provide abstract-results
         combine-props
         merge-tc-results
         tc-results->values)

;; Objects representing the rest argument are currently not supported
(define/cond-contract (abstract-results results arg-names #:rest-id [rest-id #f])
  ((tc-results/c (listof identifier?)) (#:rest-id (or/c #f identifier?))
   . ->* . SomeValues?)
  (define positional-arg-objects
    (for/list ([n (in-range (length arg-names))])
      (make-Path null (cons 0 n))))
  (define-values (names objects)
    (if rest-id
        (values (cons rest-id arg-names)
                (cons -empty-obj positional-arg-objects))
        (values arg-names positional-arg-objects)))
  (tc-results->values (replace-names names objects results)))

(define (tc-results->values tc)
  (match (fix-results tc)
    [(tc-any-results: f)
     (-AnyValues f)]
    [(tc-results: ts fs os)
     (make-Values (map -result ts fs os))]
    [(tc-results: ts fs os dty dbound)
     (make-ValuesDots (map -result ts fs os) dty dbound)]))

(define/cond-contract (resolve atoms prop)
  ((listof Prop?)
   Prop?
   . -> .
   Prop?)
  (for/fold ([prop prop])
            ([a (in-list atoms)])
    (match prop
      [(AndProp: ps)
       (let loop ([ps ps] [result null])
         (match ps
           [(cons p ps)
            (cond [(contradictory? a p) -ff]
                  [(implies-atomic? a p) (loop ps result)]
                  [else (loop ps (cons p result))])]
           [_ (apply -and result)]))]
      [_ prop])))

(define (flatten-props ps)
  (let loop ([ps ps])
    (match ps
      [(list) null]
      [(cons (AndProp: ps*) ps) (loop (append ps* ps))]
      [(cons p ps) (cons p (loop ps))])))

(define/cond-contract (combine-props new-props old-props)
  ((listof Prop?) (listof Prop?)
                  . -> .
                  (values (or/c #f (listof OrProp?))
                          (or/c #f (listof (or/c TypeProp? NotTypeProp?)))))
  (define (atomic-prop? p) (or (TypeProp? p) (NotTypeProp? p)))
  (define-values (new-atoms new-formulas) (partition atomic-prop? (flatten-props new-props)))
  (let loop ([derived-ors null]
             [derived-atoms new-atoms]
             [worklist (append old-props new-formulas)])
    (match worklist
      [(cons (app (λ (p) (resolve derived-atoms p)) p)
             worklist)
       (match p
         [(OrProp: qs)
          (let or-loop ([qs qs] [result null])
            (match qs
              [(cons q qs)
               (let check-loop ([atoms derived-atoms])
                 (match atoms
                   [(cons a atoms)
                    (cond
                      [(contradictory? q a) (or-loop qs result)]
                      [(implies-atomic? a q) (loop derived-ors derived-atoms worklist)]
                      [else (check-loop atoms)])]
                   [_ (or-loop qs (cons q result))]))]
              [_ (define new-or (apply -or result))
                 (if (OrProp? new-or)
                     (loop (cons new-or derived-ors) derived-atoms worklist)
                     (loop derived-ors derived-atoms (cons new-or worklist)))]))]
         [(or (? TypeProp?)
              (? NotTypeProp?))
          (loop derived-ors (cons p derived-atoms) worklist)]

         [(AndProp: qs) (loop derived-ors derived-atoms (append qs worklist))]
         [(== -tt prop-equal?) (loop derived-ors derived-atoms worklist)]
         [(== -ff prop-equal?) (values #f #f)])]
      [_ (values derived-ors derived-atoms)])))


(define (unconditional-prop res)
  (match res
    [(tc-any-results: pset) pset]
    [(tc-results (list (tc-result: _ (PropSet: p+ p-) _) ...) _)
     (apply -and (map -or p+ p-))]))

(define (merge-tc-results results)
  (define/match (merge-tc-result r1 r2)
    [((tc-result: t1 (PropSet: p1+ p1-) o1)
      (tc-result: t2 (PropSet: p2+ p2-) o2))
     (tc-result
       (Un t1 t2)
       (-PS (-or p1+ p2+) (-or p1- p2-))
       (if (equal? o1 o2) o1 -empty-obj))])

  (define/match (same-dty? r1 r2)
    [(#f #f) #t]
    [((cons t1 dbound) (cons t2 dbound)) #t]
    [(_ _) #f])
  (define/match (merge-dty r1 r2)
    [(#f #f) #f]
    [((cons t1 dbound) (cons t2 dbound))
     (cons (Un t1 t2) dbound)])

  (define/match (number-of-values res)
    [((tc-results rs #f))
     (length rs)]
    [((tc-results rs (cons _ dbound)))
     (format "~a and ... ~a" (length rs) dbound)])


  (define/match (merge-two-results res1 res2)
    [((tc-result1: (== -Bottom)) res2) res2]
    [(res1 (tc-result1: (== -Bottom))) res1]
    [((tc-any-results: f1) res2)
     (tc-any-results (-or f1 (unconditional-prop res2)))]
    [(res1 (tc-any-results: f2))
     (tc-any-results (-or (unconditional-prop res1) f2))]
    [((tc-results results1 dty1) (tc-results results2 dty2))
     ;; if we have the same number of values in both cases
     (cond
       [(and (= (length results1) (length results2))
             (same-dty? dty1 dty2))
        (tc-results (map merge-tc-result results1 results2)
                    (merge-dty dty1 dty2))]
       ;; otherwise, error
       [else
        (tc-error/expr "Expected the same number of values, but got ~a and ~a"
                         (length results1) (length results2))])])

  (for/fold ([res (ret -Bottom)]) ([res2 (in-list results)])
    (merge-two-results res res2)))
