# Catálogo inicial de features

## Regras

- Toda feature é calculada com `series_cutoff` anterior ao primeiro mapa da série.
- O holdout iniciado em 2026-01-01 permanece fora da seleção e do tuning.
- Patch, playoffs, bans e ordem do draft não entram no modelo.
- Duração observada do próprio mapa nunca entra na previsão.
- Estatísticas pós-jogo usadas para criar uma feature pertencem somente ao histórico anterior ao cutoff.

## Disponíveis na camada canônica

| Campo | Papel | Uso |
|---|---|---|
| `league_canonical` | contexto | feature permitida com pooling |
| `game_datetime` | tempo do evento | corte temporal e auditoria |
| `series_cutoff` | cutoff | controle obrigatório de leakage |
| `map_number` | identificação | contrato e segmentação, não feature inicial |
| `blue_team_id`, `red_team_id` | entidades | efeitos regularizados e amostra |
| `blue_team_name`, `red_team_name` | auditoria | fallback de identidade, não encoding principal |
| `blue_kills`, `red_kills` | componentes do target | histórico anterior por equipe |
| `total_kills_game` | target | variável prevista |
| `game_length_seconds` | pós-jogo | diagnóstico e challenger de duração |
| `patch` | auditoria | diagnóstico de drift, proibido como feature |
| `playoffs` | auditoria | avaliação segmentada, proibido como feature |
| `datacompleteness` | qualidade | filtro e warning |
| `source_file`, `source_season` | linhagem | auditoria e reprodução |

## Features temporais planejadas

| Grupo | Feature | Estado |
|---|---|---|
| liga | PMF empírica com shrinkage global | implementada como baseline |
| recência | janelas de 12, 18, 24 e 36 meses | em avaliação |
| recência | meias-vidas de 90, 180 e 365 dias | em avaliação |
| equipe | ataque e defesa com shrinkage | pendente |
| equipe | kills e deaths permitidas por minuto | aprovada para teste preditivo |
| equipe | combined kills por minuto | aprovada para teste preditivo |
| equipe | jogos efetivos de combined kills por minuto | implementada como cobertura recente |
| equipe | menor cobertura efetiva entre Blue e Red | gate selecionado em 1 jogo efetivo |
| equipe | dano causado e recebido por minuto | aprovada para teste preditivo |
| equipe | kills e deaths até 15 minutos | segunda camada, cobertura de 71,5% |
| equipe | estabilidade de escalação | pendente |
| jogador | histórico por função e por minuto | pendente |
| campeão | experiência jogador–campeão e equipe–campeão | pendente |
| composição | atributos e arquétipos versionados | pendente de taxonomia aprovada |

## Campos deliberadamente excluídos

`patch`, `playoffs`, bans, ordem do draft, first pick e odds não serão usados como features. Podem permanecer em relatórios de diagnóstico, auditoria ou avaliação segmentada.

## Variáveis não prioritárias após estudo de estabilidade

- First blood teve estabilidade próxima de zero.
- Duração média bruta mostrou pouca persistência e permanece apenas no challenger de duração.
- Objetivos brutos não mostraram relação forte com intensidade futura.
- Conversão simples de kills por dano foi menos estável que dano e kills por minuto separados.
