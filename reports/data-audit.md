# Auditoria inicial dos dados

Data da execução: 2026-07-23.

## Escopo

Foram validados os cinco arquivos locais do Oracle's Elixir, referentes às temporadas de 2022 a 2026. O manifesto preserva nome do arquivo, temporada declarada, origem, data de recebimento e SHA-256.

## Estrutura

- 603.456 linhas.
- 50.288 mapas antes do filtro de competições.
- 165 colunas em cada arquivo.
- 12 linhas em todos os mapas: dez jogadores e duas equipes.
- 75.420 linhas declaradas como `partial`.
- Nenhum download automático.

## Recorte canônico

Após aplicar a taxonomia de competições:

- 13.752 mapas incluídos.
- 11.866 mapas das sete ligas-alvo.
- 1.886 mapas auxiliares.
- 13.752 targets válidos.
- 13.752 mapas com série derivada elegível.
- 1 registro interrompido excluído por ID após auditoria.

Mapas por liga-alvo:

| Liga | Mapas |
|---|---:|
| CBLOL | 1.143 |
| LCK | 2.340 |
| LCS | 1.133 |
| LEC | 1.377 |
| LES | 1.124 |
| LFL | 1.233 |
| LPL | 3.516 |

## Qualidade do target

O target é calculado uma única vez pela soma de `teamkills` das duas linhas de equipe. A soma das kills dos dez jogadores é uma validação crítica.

Foram encontrados 661 mapas em que a soma de deaths dos jogadores difere do total de kills. Esses casos permanecem válidos e recebem o alerta `player_deaths_mismatch`, pois execuções podem produzir deaths sem kill adversária. Nenhum desses registros apresentou divergência entre team kills e player kills.

## Séries

A chave inicial usa liga canônica, data UTC e o par de equipes sem considerar side. Uma reinicialização do número do mapa inicia nova série no mesmo dia. Registros com o mesmo mapa e o mesmo horário permanecem ambíguos e inelegíveis.

Na execução atual não restaram séries ambíguas.

## Exclusão auditada

O registro `ESPORTSTMNT01_3408461`, de Liiv SANDBOX contra T1 em 2023-08-04, contém 201 segundos e placar 0-0 no CSV local. A fonte de conferência registra o mapa 2 concluído com 40:43 e placar 27-12. Por isso, o registro local foi classificado como `aborted_or_incomplete_capture` e excluído exatamente por `gameid`, sem regra automática de duração.

O mapa concluído não está presente no CSV local. A série permanece utilizável com uma lacuna explícita de cobertura.

## Artefatos locais

- `artifacts/oracle_elixir_file_audit.csv`
- `artifacts/canonical_games_summary.csv`
- `artifacts/canonical_games_by_league.csv`
- `data/interim/canonical_games.rds`
- `data/interim/game_quality_events.rds`
- `data/interim/excluded_games.rds`
- `data/processed/lolkills.duckdb`
- `data/processed/canonical_games.parquet`
- `data/processed/game_quality_events.parquet`
- `data/processed/excluded_games.parquet`

Dados brutos, intermediários e artefatos permanecem fora do Git.
