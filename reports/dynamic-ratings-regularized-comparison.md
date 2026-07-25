# Ratings dinâmicos e regressões regularizadas

Data da decisão: 24/07/2026.

## Interface

O Streamlit agora mostra somente identidades atuais de equipes que disputaram
ao menos um mapa em 2026 nas sete ligas suportadas:

| Liga | Equipes visíveis |
|---|---:|
| CBLOL | 8 |
| LCK | 10 |
| LCS | 8 |
| LEC | 11 |
| LES | 8 |
| LFL | 21 |
| LPL | 14 |

Equipes e jogadores com pouca amostra recebem um aviso, mas continuam
selecionáveis. O bloqueio ocorre somente ao calcular a previsão. Quando não há
elenco associado à equipe no snapshot, o fallback global de jogadores mostra
também a equipe conhecida do jogador.

Foram testados carregamento, troca imediata de liga, remoção de identidades
inativas, troca para equipe de pouca amostra, aviso de bloqueio e uma previsão
completa.

## Ratings

Ataque é medido por kills por minuto. Defesa é medida pela capacidade de evitar
deaths por minuto. Os índices valem 100 na referência:

- `attack_league` e `defense_league`: comparação com as outras equipes da
  mesma liga;
- `attack_global` e `defense_global`: comparação com todas as outras equipes
  das ligas-alvo.

A equipe comparada é retirada da média de referência. Os históricos recebem
shrinkage de 20 jogos e meia-vida de 60 dias.

Momentum compara uma tendência recente de 21 dias com uma tendência de
120 dias. Valor positivo indica aumento recente.

Agressividade usa o estado do jogo aos 15 minutos:

- à frente quando o gold diff é positivo;
- atrás quando o gold diff é negativo;
- agressiva acima de 103 contra a média da liga;
- pacífica abaixo de 97;
- neutra entre 97 e 103.

Snowball é medido somente quando a equipe possuía vantagem mínima de duas kills
aos 15 minutos. O índice combina:

- frequência de conversão da vantagem em vitória;
- rapidez para encerrar os jogos convertidos.

Foram produzidas 23.732 linhas históricas de equipe e 11.866 mapas. Nenhuma
linha usou resultado ocorrido no cutoff ou depois dele.

## Regressões regularizadas em 2022–2025

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| Ridge com ratings e comportamento | 4,5456 | 3,4916 | 92,84% |
| Ridge completo | 4,5463 | 3,4919 | 92,91% |
| Ridge estrutural sem novos ratings | 4,5535 | 3,4929 | 92,96% |
| Elastic Net 0,25 | 4,5604 | 3,4949 | 92,96% |
| Elastic Net 0,50 | 4,5627 | 3,4954 | 92,97% |
| Lasso | 4,5630 | 3,4954 | 92,89% |
| V1 | 4,5622 | 3,4924 | 91,73% |
| PCA | 4,5571 | 3,4905 | 91,39% |

O melhor Ridge melhorou o CRPS em 0,36% contra o V1 e 0,25% contra o PCA. O
intervalo temporal contra o V1 foi de -0,0372 a 0,0032 CRPS. Portanto, ainda
inclui a possibilidade de ganho zero.

O Ridge venceu o V1 em sete dos nove folds. Perdeu em 2023 Q1 e 2025 Q2. Por
liga, melhorou seis das sete ligas contra o V1 e piorou apenas a LCK.

## Ablação

| Conjunto | CRPS |
|---|---:|
| Base + ratings + agressividade + snowball | 4,5456 |
| Base + ratings + momentum + comportamento | 4,5463 |
| Base + ratings | 4,5469 |
| Base + ratings + momentum | 4,5491 |
| Base estrutural | 4,5535 |

Ataque e defesa relativos trouxeram ganho. Agressividade e snowball trouxeram
um ganho adicional pequeno. Momentum piorou a média nesta versão. Ele permanece
como indicador de diagnóstico, mas foi retirado do challenger congelado.

## Comparação secundária em 2026

| Modelo | CRPS | Log Score | Cobertura 90% |
|---|---:|---:|---:|
| Ridge com ratings e comportamento | 4,4717 | 3,4797 | 92,68% |
| Ridge completo | 4,4757 | 3,4804 | 92,68% |
| PCA | 4,4928 | 3,4836 | 90,73% |
| V1 | 4,4975 | 3,4838 | 90,37% |

O melhor Ridge melhorou 0,57% contra o V1 em 2026. A probabilidade bootstrap
de ter sido melhor foi 97,4%, mas 2026 não pode alterar a seleção.

### Métricas por linha do melhor Ridge

| Período | Linha | Brier | Log Loss | Erro de calibração |
|---|---:|---:|---:|---:|
| 2022–2025 | 24,5 | 0,2257 | 0,6428 | -0,0271 |
| 2022–2025 | 27,5 | 0,2329 | 0,6577 | -0,0201 |
| 2022–2025 | 30,5 | 0,2057 | 0,5982 | -0,0086 |
| 2026 | 24,5 | 0,2084 | 0,6043 | 0,0079 |
| 2026 | 27,5 | 0,2378 | 0,6680 | 0,0157 |
| 2026 | 30,5 | 0,2279 | 0,6477 | 0,0247 |

## Decisão

O V1 continua em produção. O modelo `ridge_plus_behavior` foi congelado como
challenger prospectivo, treinado em 11.866 mapas e com cutoff de resultados em
22/07/2026 20:02:30 UTC.

Ele não foi promovido porque o intervalo de confiança no desenvolvimento ainda
cruza zero. Novos mapas posteriores ao cutoff serão a confirmação limpa.
