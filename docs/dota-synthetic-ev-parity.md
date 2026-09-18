# Paridade do EV sintético Dota 2/LoL

A aba Dota 2 usa o mesmo fluxo de cotação sintética da aba LoL. A linha soft é uma linha de avaliação válida e não precisa coincidir com a linha Pinnacle sintética prevista.

Para cada cotação, a inferência preserva a linha prevista do Dota e calcula a probabilidade na linha oferecida pela soft book:

```text
central_logit = logit(probabilidade prevista na linha sintética)
  + slope_por_kill * (linha sintética prevista - linha soft)
```

Com essa probabilidade são calculados:

- odds justas Over e Under;
- EV pontual Over e Under;
- EV conservador Over e Under;
- probabilidade sem vig da cotação soft;
- confiança, lado recomendado e ação manual;
- odds finais previstas da Pinnacle e hold estimado.

As cotações 1, 2 e 3 são independentes. Uma divergência entre linhas não gera bloqueio nem `EV não calculado`. O fluxo continua em comparação manual, com `stake = 0.0` e `automatic_betting_approved = false`.

## Bundle atual

O bundle Dota preserva a calibração necessária para o fluxo:

- inclinação de probabilidade por kill derivada de 1.659 grupos de movimentos dentro de evento do BettingIsCool;
- intervalo de linha derivado dos resíduos out-of-fold;
- intervalo logit de preço derivado dos resíduos out-of-fold;
- hold mediano histórico;
- EV conservador mínimo de 5%.

## Verificação

```powershell
py -3 -m pytest tests_python -q
& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' -e "testthat::test_file('tests/testthat/test-bundle-contract.R')"
py -3 -m py_compile app/dota_inference.py app/dota_synthetic.py
```
