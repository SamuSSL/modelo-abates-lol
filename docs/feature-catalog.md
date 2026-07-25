# Catálogo inicial de features

## Features da rodada estrutural

### Duração prevista

- média e dispersão histórica de duração de cada equipe, congeladas pré-série;
- liga;
- efeitos encolhidos da equipe e do adversário;
- scores funcionais das duas composições.

### Intensidade de conflito

- kills combinadas por minuto;
- ataque histórico da equipe e deaths permitidas pelo adversário;
- dano causado e recebido por minuto;
- intensidade dos jogadores por função;
- familiaridade jogador–campeão encolhida;
- scores e diferenças dos arquétipos funcionais.

### Regras

- duração observada do mapa-alvo é target auxiliar, nunca feature;
- IDs de equipe e adversário entram somente por efeitos regularizados;
- interação jogador–campeão é calculada antes do cutoff da série;
- cortes de `qcut` e componentes de PCA são objetos do fold de treino;
- 2026 não fornece médias, categorias, escalas, cortes ou hiperparâmetros.
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
| equipe | ataque e defesa com shrinkage | implementada, índices local e global |
| equipe | kills e deaths permitidas por minuto | aprovada para teste preditivo |
| equipe | combined kills por minuto | aprovada para teste preditivo |
| equipe | jogos efetivos de combined kills por minuto | implementada como cobertura recente |
| equipe | menor cobertura efetiva entre Blue e Red | gate selecionado em 1 jogo efetivo |
| equipe | dano causado e recebido por minuto | aprovada para teste preditivo |
| equipe | kills e deaths até 15 minutos | implementada em snowball e estado aos 15 |
| equipe | estabilidade de escalação | pendente |
| jogador | histórico por função e por minuto | implementada |
| campeão | experiência jogador–campeão e equipe–campeão | interação jogador–campeão implementada |
| composição | atributos e arquétipos versionados | taxonomia automática completa, aguardando revisão |

## Ratings dinâmicos e comportamento

Todos os ratings usam somente mapas encerrados antes do cutoff da série e
shrinkage de 20 jogos em direção à referência.

- `rating_attack_league`: kills por minuto da equipe contra a média das outras
  equipes da mesma liga. 100 representa a média.
- `rating_defense_league`: capacidade de evitar deaths contra a média das
  outras equipes da liga. Acima de 100 representa defesa melhor.
- `rating_attack_global` e `rating_defense_global`: mesma interpretação contra
  todas as ligas-alvo.
- `momentum_attack`: ataque recente de 21 dias contra a tendência de 120 dias.
- `momentum_mortality`: deaths recentes contra a tendência longa.
- `momentum_bloodiness`: kills combinadas recentes contra a tendência longa.
- `aggression_ahead`: ritmo de kills quando a equipe possuía vantagem de ouro
  aos 15 minutos.
- `aggression_behind`: ritmo de kills quando possuía desvantagem aos 15.
- `behavior_ahead_profile` e `behavior_behind_profile`: classificação
  `aggressive`, `neutral` ou `peaceful` relativa à liga. A zona neutra fica
  entre 97 e 103 para evitar classificar diferenças mínimas como estilo.
- `snowball_conversion`: frequência de vitória após vantagem mínima de duas
  kills aos 15 minutos.
- `snowball_close_speed`: rapidez de encerramento quando a vantagem foi
  convertida em vitória.
- `snowball_index`: combinação da conversão e da velocidade de encerramento.

As médias de liga e globais excluem o histórico da própria equipe comparada.
Isso evita aproximar artificialmente todo rating de 100.

## Campos deliberadamente excluídos

`patch`, `playoffs`, bans, ordem do draft, first pick e odds não serão usados como features. Podem permanecer em relatórios de diagnóstico, auditoria ou avaliação segmentada.

## Variáveis não prioritárias após estudo de estabilidade

- First blood teve estabilidade próxima de zero.
- Duração média bruta mostrou pouca persistência e permanece apenas no challenger de duração.
- Objetivos brutos não mostraram relação forte com intensidade futura.
- Conversão simples de kills por dano foi menos estável que dano e kills por minuto separados.
