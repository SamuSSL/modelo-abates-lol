# Paridade do fluxo de EV Dota 2/LoL

## Objetivo

Fazer a aba Dota 2 reproduzir o contrato operacional de cotação usado pela aba LoL quando a linha da soft book é diferente da linha sintética prevista.

## Diagnóstico confirmado

O adaptador Dota calcula a probabilidade no modelo sem receber a linha soft e depois bloqueia `ev_over` e `ev_under` quando a diferença entre a linha soft e a linha prevista é maior que `0.26`. O LoL recebe a linha soft no cálculo e ajusta a probabilidade para aquela linha. A mensagem `EV não calculado` é, portanto, uma diferença de implementação, não uma restrição do mercado.

## Desenho aprovado

O bundle Dota continuará fornecendo a linha prevista e a probabilidade/preço no ponto previsto. Para cada cotação soft, a inferência Dota calculará a probabilidade na linha da cotação usando a mesma transformação logística de linha utilizada pelo LoL:

```text
central_logit = predicted_price_logit
  + slope_per_kill * (predicted_line_raw - soft_line)
```

O resultado de cada cotação terá o mesmo contrato de saída do LoL:

- linha prevista contínua e meia-linha operacional;
- intervalo inferior e superior da linha;
- probabilidade Over e Under na linha soft;
- odds justas;
- EV pontual Over e Under;
- EV conservador Over e Under;
- confiança;
- lado recomendado;
- ação manual ou abstinência;
- `stake: 0.0` e `automatic_betting_approved: false`;
- probabilidade sem vig da cotação soft;
- preço final previsto da Pinnacle e hold previsto.

As cotações 1, 2 e 3 serão calculadas separadamente. A linha soft não será usada como feature do modelo Dota nem alterará a linha sintética prevista.

## Dados do bundle

O bundle Dota passará a preservar a inclinação de probabilidade por kill, o intervalo residual logit do preço e o EV conservador mínimo. Esses valores serão derivados dos dados históricos de movimentos do BettingIsCool e dos resíduos out-of-fold do modelo Dota, com origem registrada na proveniência do bundle.

## Interface

A aba Dota exibirá os mesmos blocos funcionais do LoL: resultado principal, intervalo, EV conservador, probabilidades/odds justas, preços finais previstos e confiômetro por cotação. O aviso de linha divergente será removido, pois a divergência é uma entrada válida para o cálculo.

## Segurança e limites

O fluxo continuará sendo apenas comparação manual. Nenhuma recomendação poderá liberar aposta automática. Falta de histórico, bundle inválido ou modelo não promovido continuará bloqueando a previsão.

## Testes de aceitação

1. Uma linha soft igual à prevista calcula EV.
2. Uma linha soft acima da prevista calcula EV e altera a probabilidade Over na direção correta.
3. Uma linha soft abaixo da prevista calcula EV e altera a probabilidade Over na direção correta.
4. As cotações 1, 2 e 3 produzem resultados independentes.
5. O contrato Dota contém os campos do contrato LoL e mantém aposta automática bloqueada.
6. A interface não exibe `EV não calculado` apenas por divergência de linha.
