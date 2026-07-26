# Hipóteses de pesquisa

## Fenômeno

O fenômeno não é apenas “Over ou Under”. Isso é resultado final e contém muito ruído.

O objeto de estudo será a intensidade esperada de kills de um mapa. Ela será decomposta em três partes:

1. **Ritmo de conflito:** frequência com que as equipes criam ou aceitam situações perigosas.
2. **Conversão:** capacidade de transformar pressão, dano e lutas em kills.
3. **Tempo de exposição:** duração provável do mapa durante a qual kills podem ocorrer.

Representação conceitual:

```text
kills esperadas ≈ intensidade de conflito × conversão × duração esperada
```

Essas partes não são observadas perfeitamente. Serão estimadas por indicadores históricos disponíveis antes da série.

## O que sabemos

- Totais recentes de kills são barulhentos.
- Médias pequenas podem produzir extremos falsos.
- Ligas e temporadas possuem ritmos diferentes.
- O ambiente mudou mais rápido em 2025.
- Meias-vidas muito curtas perdem amostra por causa do calendário.
- Patch produz mudanças observáveis, mas continua proibido como feature.

## O que ainda não sabemos

Não existe evidência de que o mercado precifica draft, sinergia ou familiaridade de campeão incorretamente. Não temos odds históricas completas para testar essa afirmação.

Portanto:

- sinal preditivo não será chamado automaticamente de edge;
- hipótese de mercado será avaliada prospectivamente;
- ROI só será calculado em apostas confirmadas;
- nenhuma feature será mantida apenas por parecer intuitiva.

## Hipóteses principais

### H0 — Baseline

Liga e recência explicam boa parte da distribuição.

Teste: distribuição empírica com shrinkage e meia-vida aprovada.

Uso: referência mínima que todo modelo precisa superar.

### H1 — Ritmo de conflito da equipe é persistente

Algumas equipes criam e aceitam mais conflitos letais do que outras, mesmo após regressão à média.

Indicadores candidatos:

- kills por minuto;
- deaths permitidas por minuto;
- combined kills por minuto;
- kills e deaths até 10 e 15 minutos;
- first blood;
- dano por minuto;
- duração histórica.

Teste de estabilidade: comparar blocos consecutivos de jogos da mesma equipe.

Teste preditivo: usar apenas blocos anteriores para prever intensidade futura.

Falsificação: remover indicador se estabilidade ou ganho temporal não persistir.

### H2 — Ataque e exposição defensiva são diferentes

Uma equipe pode matar muito porque ataca bem ou porque joga partidas caóticas e também morre muito.

Modelo simples:

```text
intensidade esperada da equipe A
= ataque de A + exposição defensiva de B + nível da liga
```

Efeito usa pooling parcial. Equipe com poucos jogos fica próxima da média da liga.

Falsificação: decomposição precisa superar uma única média de total de kills.

### H3 — Duração é mecanismo, não feature observada

Mapas longos oferecem mais tempo para kills, mas duração do próprio mapa é desconhecida na previsão.

Teste:

- modelo direto do total;
- intensidade por minuto multiplicada por duração prevista;
- Gamma e log-normal para duração.

Falsificação: submodelo de duração sai se não melhorar CRPS e calibração.

### H4 — Draft muda intensidade condicional

Composições podem aumentar ou reduzir engage, disengage, dive, pick, scaling e capacidade de encerrar o jogo.

Teste:

1. estimar baseline de liga, equipes e jogadores;
2. adicionar campeões e atributos da composição;
3. medir ganho fora da amostra;
4. comparar contra ablação sem draft.

Falsificação: draft sai do modelo se não melhorar distribuição de forma estável.

### H5 — Familiaridade jogador–campeão importa

Experiência anterior do jogador com campeão pode afetar execução e variância.

Indicadores:

- mapas anteriores no campeão;
- desempenho anterior por função;
- estabilidade do jogador na equipe;
- amostra efetiva com decaimento.

Falsificação: efeito precisa sobreviver ao controle por jogador, equipe, função e campeão.

### H6 — Sinergia vale mais que soma isolada

Cinco campeões podem produzir comportamento diferente da soma de cinco efeitos individuais.

Teste:

- primeiro efeitos individuais regularizados;
- depois atributos agregados;
- por último arquétipos e interações simples.

Falsificação: nenhuma interação entra sem ganho temporal e amostra suficiente.

## Indicadores estáveis

Antes de usar uma variável, medir:

- correlação entre blocos consecutivos;
- variância dentro e entre equipes;
- estabilidade por liga e temporada;
- desempenho com 5, 10 e 20 jogos anteriores;
- tamanho efetivo após decaimento;
- regressão à média necessária;
- ganho fora da amostra.

Indicador “pegajoso” mantém sinal no bloco seguinte. Indicador ruidoso oscila e precisa ser descartado ou muito encolhido.

## Regressão à média

Toda estatística de equipe, jogador ou campeão terá:

- média da liga como prior;
- peso maior para amostra grande;
- peso menor para amostra antiga;
- contagem bruta e efetiva separadas;
- bloqueio operacional abaixo do mínimo aprovado.

Exemplo simples:

```text
estimativa ajustada
= peso da amostra × média observada
+ peso do prior × média da liga
```

## Ordem de construção

1. Baseline de liga e recência.
2. Ataque, defesa e ritmo de conflito das equipes.
3. Duração prevista como challenger.
4. Jogadores e estabilidade de elenco.

> Estado atual: hipóteses relacionadas a jogadores foram arquivadas por decisão
> do produto. Elas não fazem parte do V1, dos challengers ativos nem do contrato
> de inferência. A pesquisa operacional segue com efeitos de equipe e draft.
5. Campeões individuais e familiaridade.
6. Atributos e arquétipos de composição.
7. Modelos mais complexos somente após ganho comprovado.

## Critério de avanço

Cada nova camada precisa responder:

- qual mecanismo representa;
- por que deveria ser estável;
- qual informação anterior ao cutoff usa;
- como regressão à média é aplicada;
- qual teste pode rejeitar a hipótese;
- quanto melhora CRPS e calibração;
- onde piora por liga.

Sem resposta e evidência, camada não avança.
