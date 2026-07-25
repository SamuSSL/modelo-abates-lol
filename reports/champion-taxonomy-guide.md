# Guia de revisão da taxonomia de campeões

Versão atual: `2026-functional-v2`.

A planilha `champion-taxonomy-review.csv` contém 173 campeões. Todos os
scores variam de 0 a 1. Zero significa ausência ou capacidade muito baixa.
Um significa capacidade muito alta.

## Classes gerais

- `tank`, `fighter`, `assassin`, `mage`, `marksman`, `support`: classes
  oficiais multi-label.
- `attack`, `defense`, `magic`, `difficulty`: scores gerais do Data Dragon.

## Capacidades funcionais

- `engage`: capacidade de iniciar uma luta de forma confiável.
- `disengage`: capacidade de interromper ou sair de uma luta.
- `dive`: capacidade de alcançar e pressionar a linha de trás.
- `pick`: capacidade de isolar e eliminar um alvo.
- `poke`: dano ou pressão segura antes da luta.
- `siege`: capacidade de pressionar torres e espaços defensivos.
- `frontline`: capacidade de ocupar a linha de frente e absorver pressão.
- `protect`: cura, escudo, peel ou outras formas de proteger aliados.
- `scaling`: crescimento relativo de poder com tempo e recursos.
- `early_pressure`: força nos primeiros estágios do jogo.
- `skirmish`: força em lutas pequenas e móveis.
- `split_push`: capacidade de pressionar rota lateral sozinho.
- `wave_clear`: capacidade de limpar ondas rapidamente.
- `mobility`: facilidade de reposicionamento por dash, salto ou teleporte.
- `crowd_control`: quantidade e confiabilidade de controle de grupo.
- `global_pressure`: impacto em áreas distantes do mapa.
- `damage_physical`: peso esperado de dano físico.
- `damage_magic`: peso esperado de dano mágico.
- `execution_difficulty`: dificuldade mecânica e de execução.
- `snowball_dependency`: dependência de vantagem inicial para funcionar bem.

## Arquétipos das composições

Os scores de composição são médias dos cinco campeões:

- `engage`: engage, controle de grupo, frontline e mobilidade.
- `pick`: pick, controle de grupo e mobilidade.
- `poke_siege`: poke, siege e wave clear.
- `dive`: dive, mobilidade e pressão inicial.
- `protect`: proteção, disengage e scaling.
- `front_to_back`: frontline, proteção, scaling e equilíbrio de dano.
- `split_map`: split push, pressão global e wave clear.
- `skirmish`: skirmish, pressão inicial e mobilidade.
- `scaling`: scaling, wave clear e proteção.

O maior score vira o arquétipo primário. O segundo maior vira o secundário.
A confiança depende da distância entre os dois primeiros e da cobertura das
informações.

## Como revisar

Altere os scores diretamente na planilha. Use `review_status` como
`approved`, `changed` ou `uncertain`. Explique mudanças em `review_notes`.

Esta versão foi gerada automaticamente a partir de classes, atributos e texto
das habilidades. Ela não deve ser tratada como avaliação especializada.
