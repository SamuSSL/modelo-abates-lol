# Estabilidade das métricas subjacentes

Data da execução: 2026-07-23.

## Pergunta

Qual estatística de uma equipe tende a continuar existindo nos jogos seguintes?

Teste:

1. calcular média em bloco passado;
2. calcular média no bloco seguinte da mesma equipe;
3. medir quanto comportamento se repete;
4. medir quanto bloco passado antecipa ritmo de kills futuro.

Foram usados blocos de 5, 10 e 20 mapas. Holdout de 2026 ficou excluído.

## Como ler

`stability_spearman` próximo de 1 significa comportamento pegajoso. Próximo de zero significa ruído.

`future_intensity_spearman` mede quanto indicador passado antecipa combined kills por minuto no bloco seguinte.

Correlação não garante ganho no modelo. Ela serve para escolher o que merece teste preditivo.

## Blocos de 10 mapas

| Métrica | Pares | Estabilidade | Relação com intensidade futura | Relação com kills futuras |
|---|---:|---:|---:|---:|
| dano recebido por minuto | 1.853 | 0,791 | 0,355 | 0,380 |
| dano por minuto | 1.853 | 0,702 | 0,392 | 0,407 |
| combined kills por minuto | 1.853 | 0,463 | 0,463 | 0,431 |
| kills por minuto | 1.853 | 0,442 | 0,336 | 0,313 |
| combined kills até 15 | 1.266 | 0,370 | 0,334 | 0,315 |
| deaths por minuto | 1.853 | 0,342 | 0,206 | 0,196 |
| duração média | 1.853 | 0,214 | -0,147 | -0,057 |
| first blood | 1.853 | 0,051 | -0,023 | -0,016 |

## Consistência com mais jogos

| Métrica | Estabilidade com 5 | com 10 | com 20 |
|---|---:|---:|---:|
| dano recebido por minuto | 0,708 | 0,791 | 0,832 |
| dano por minuto | 0,607 | 0,702 | 0,772 |
| combined kills por minuto | 0,390 | 0,463 | 0,563 |
| kills por minuto | 0,323 | 0,442 | 0,584 |
| deaths por minuto | 0,236 | 0,342 | 0,452 |
| combined kills até 15 | 0,283 | 0,370 | 0,474 |

Mais jogos reduzem ruído. Isso confirma necessidade de regressão à média para amostras pequenas.

## Cobertura

- Métricas finais e por minuto: 100%.
- Métricas até 10 e 15 minutos: 71,5%.
- Assists por kill: 99,7%.
- Heralds: 98,8%.

Registros `partial` podem usar métricas completas. Métrica ausente não será imputada silenciosamente.

## Variáveis críticas propostas

### Núcleo

1. `combined_kills_per_minute`: ritmo total de conflito.
2. `damage_per_minute`: pressão ofensiva.
3. `damage_taken_per_minute`: exposição a pressão.
4. `kills_per_minute`: conversão ofensiva.
5. `deaths_per_minute`: exposição defensiva.

### Segunda camada

6. `combined_kills_at_15`: conflito inicial.
7. `kills_at_15` e `deaths_at_15`: separação do início ofensivo e defensivo.

### Não prioritárias

- `first_blood`: quase nenhum sinal persistente.
- duração média bruta: pouca estabilidade; duração deve ser submodelo.
- barons e dragons brutos: fraca relação com intensidade futura.
- kills por dano: conversão instável.
- gold diff até 15: algum estilo persistente, pouca relação direta com kills futuras.

## Próximo teste

Construir features anteriores ao cutoff com:

- meia-vida de 60 dias;
- prior da liga;
- ataque e defesa separados;
- contagem bruta;
- amostra efetiva;
- versão sem e com dano;
- versão sem e com early game.

Cada grupo entra por ablação. Nenhuma métrica recebe status definitivo antes do rolling-origin preditivo.

## Artefatos

- `reports/metric-stability.html`
- `data/interim/team_map_metrics.rds`
- `data/processed/team_map_metrics.parquet`
- `artifacts/research/metric_stability_summary.csv`
- `artifacts/research/metric_stability_by_league.csv`
- `artifacts/research/metric_coverage.csv`
- `artifacts/research/metric_stability_details.rds`
