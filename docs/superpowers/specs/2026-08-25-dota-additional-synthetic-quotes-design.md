# Dota 2 Additional Synthetic Quotes Design

## Goal

Replicar no HUD de Dota 2 o comportamento já existente no HUD de LoL para adicionar opcionalmente as cotações sintéticas 2 e 3 durante a comparação manual com uma soft book.

## Observed reference

- O HUD de LoL mantém a cotação 1 sempre visível.
- As cotações 2 e 3 são ativadas por checkboxes.
- Cada cotação ativada recebe casa, linha, odd Over e odd Under.
- A previsão do modelo é a mesma; cada cotação é avaliada separadamente.

## Design

O Dota continuará com uma única previsão automática baseada nas features point-in-time. A interface coletará uma cotação principal e, quando ativadas, duas cotações adicionais. A função de predição será chamada uma vez por cotação, sem adicionar linha, preço ou casa soft às features do modelo.

O resultado exibirá a previsão principal e um bloco de comparação para cada cotação ativa. Cada bloco preservará linha, casa, odds justas, EV e status de correspondência da linha. A persistência append-only continuará registrando a entrada da cotação principal; as cotações adicionais também serão preservadas no payload da sessão para não perder a comparação executada.

## Constraints

- Labels e comportamento devem seguir o padrão do LoL.
- As cotações 2 e 3 são opcionais.
- Linhas devem continuar sendo half-lines e odds maiores que 1.00.
- Linha e odds soft não entram no modelo Dota.
- automatic_betting_approved continua false.
- Não alterar o modelo, bundle, catálogo ou contrato pré-draft.
- Não alterar o fluxo do LoL.

## Acceptance criteria

1. O teste da aba Dota encontra os seletores de cotação sintética 2 e 3.
2. Sem ativar checkboxes, uma cotação continua sendo calculada como antes.
3. Com uma ou duas cotações adicionais ativas, cada uma é avaliada separadamente.
4. Casas adicionais vazias bloqueiam o cálculo com erro explícito.
5. A comparação permanece manual e nenhuma aposta automática é autorizada.
