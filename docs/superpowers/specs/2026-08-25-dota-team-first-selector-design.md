# Dota 2 Team-First Selector Design

## Goal

Permitir que a previsão Dota selecione equipes pelo universo global de times elegíveis das competições Tier S/A, sem exigir que ambas estejam na competição escolhida no formulário.

## Design decision

O seletor de competição será mantido como contexto opcional. A opção padrão será Automática, que usa o histórico global anterior ao cutoff. Quando uma competição for escolhida, o resolvedor tentará priorizar snapshots daquela competição e completará cada equipe com o histórico global quando ela não tiver histórico suficiente naquele contexto.

As equipes serão deduplicadas pelo team_id canônico. O nome exibido será o nome mais recente conhecido no catálogo, e cada opção mostrará a quantidade de competições S/A em que o ID apareceu. A elegibilidade continua baseada na existência de histórico point-in-time no catálogo; não será criado um limiar arbitrário novo nesta alteração.

## Guarantees

- Um time recém-chegado à competição atual continua selecionável se possuir histórico anterior válido.
- Um time sem snapshot anterior ao horário planejado continua bloqueado com mensagem explícita.
- A liga não entra como feature do modelo.
- O cutoff histórico continua sendo anterior ao início planejado.
- IDs, aliases e o escopo S/A permanecem os mesmos da fonte canônica.

## Acceptance criteria

1. A interface oferece Automática como primeira opção de competição.
2. As duas listas de equipes usam o universo global deduplicado, não a lista da competição selecionada.
3. A escolha de competição prioriza o contexto quando disponível e mantém fallback global.
4. O metadata identifica se a resolução foi global ou contextual com fallback.
5. O fluxo anterior de previsão, odds e aposta manual continua funcionando.
