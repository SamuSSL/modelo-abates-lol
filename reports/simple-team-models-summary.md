# Modelos probabilísticos simples de equipe

## Pergunta

Indicadores históricos de equipe conseguem prever a distribuição de kills
melhor que uma distribuição recente por liga?

O teste usou 7.586 mapas em nove períodos de validação entre 2023 e 2025.
Somente informações anteriores ao início de cada série foram usadas. O ano de
2026 continuou fechado.

## Resultado principal

| Modelo | Informação usada | CRPS | Log Score | Cobertura 90% |
|---|---|---:|---:|---:|
| Negative Binomial + ritmo | liga e ritmo das duas equipes | 4,5861 | 3,4981 | 91,60% |
| Negative Binomial + ataque/defesa | anterior mais balanço ataque-defesa | 4,5945 | 3,5000 | 91,48% |
| Negative Binomial + dano | anterior mais dano causado e recebido | 4,6013 | 3,5015 | 91,56% |
| Negative Binomial por liga | somente liga | 4,6572 | 3,5143 | 90,94% |
| Baseline empírico | distribuição recente da liga | 4,6803 | 3,5930 | 91,29% |
| Poisson por liga | somente liga | 4,8426 | 3,8195 | 72,91% |

CRPS menor é melhor. O vencedor desta rodada foi Negative Binomial com ritmo.
Ele reduziu o CRPS em 0,0942, ou 2,01%, contra o baseline empírico. O intervalo
bootstrap da diferença ficou entre -0,1244 e -0,0657. Portanto, o ganho não
parece fruto de poucos jogos aleatórios.

## Explicação simples

Poisson supõe que a variação dos jogos é limitada. LoL real varia muito mais:
alguns mapas acabam controlados e outros viram sequências longas de lutas.
Por isso os intervalos do Poisson ficaram estreitos demais e cobriram somente
72,91% dos resultados quando deveriam cobrir perto de 90%.

Negative Binomial aceita essa variação extra. Só essa troca já melhorou o
baseline. Depois, informar o ritmo recente das duas equipes trouxe novo ganho.
Ritmo aqui significa frequência histórica de kills e deaths por minuto,
regularizada para não confiar demais em amostra pequena.

Separar o mesmo ritmo em ataque e exposição defensiva não ajudou. O CRPS piorou
0,0084 contra o modelo de ritmo, com intervalo entre 0,0021 e 0,0156. Adicionar
dano também piorou 0,0067; o intervalo entre -0,0041 e 0,0191 inclui empate.
Pela regra pré-registrada, fica o modelo mais simples.

## Consistência

O modelo de ritmo venceu o baseline em oito dos nove folds. A única piora foi
2023 Q2, de 0,0075 de CRPS. Ele também venceu nas sete ligas:

| Liga | Diferença de CRPS contra baseline |
|---|---:|
| CBLOL | -0,0667 |
| LCK | -0,1034 |
| LCS | -0,0086 |
| LEC | -0,0985 |
| LES | -0,1595 |
| LFL | -0,0936 |
| LPL | -0,0685 |

O ganho da LCS foi pequeno, mas não houve liga com piora média. O coeficiente de
ritmo foi positivo nos nove folds. Isso significa que equipes historicamente
envolvidas em mais conflitos por minuto receberam previsão maior de kills.

## Decisão

Estes números usam o prior de 10 jogos selecionado no estudo de shrinkage.
`nb_pace` avança como líder de desenvolvimento. `poisson_league`,
`nb_attack_defense` e `nb_pressure` são rejeitados nesta forma. `nb_league`
permanece como baseline paramétrico.

Nenhum modelo foi promovido para aposta. Ainda faltam sensibilidade ao
shrinkage de equipe, limites de amostra, draft, calibração por linha e holdout
final. O ano de 2026 não foi aberto.
