data {
  int<lower=1> N;
  int<lower=1> M;
  int<lower=1> L;
  int<lower=1> T;
  int<lower=1> K_intensity;
  int<lower=1> K_duration;
  array[N] int<lower=0> blue_kills;
  array[N] int<lower=0> red_kills;
  vector<lower=0>[N] duration;
  array[N] int<lower=1, upper=L> league;
  array[N] int<lower=1, upper=T> blue_team;
  array[N] int<lower=1, upper=T> red_team;
  matrix[N, K_intensity] X_intensity;
  matrix[N, K_duration] X_duration;
  vector<lower=0>[N] observation_weight;
  array[M] int<lower=1, upper=L> league_pred;
  array[M] int<lower=1, upper=T> blue_team_pred;
  array[M] int<lower=1, upper=T> red_team_pred;
  matrix[M, K_intensity] X_intensity_pred;
  matrix[M, K_duration] X_duration_pred;
}
parameters {
  real alpha_intensity;
  real alpha_duration;
  vector[K_intensity] beta_intensity;
  vector[K_duration] beta_duration;
  vector[L] z_league_intensity;
  vector[L] z_league_duration;
  vector[T] z_attack;
  vector[T] z_exposure;
  vector[T] z_team_duration;
  real<lower=0> sigma_league_intensity;
  real<lower=0> sigma_league_duration;
  real<lower=0> sigma_attack;
  real<lower=0> sigma_exposure;
  real<lower=0> sigma_team_duration;
  real<lower=0> sigma_duration;
  real<lower=0> phi;
}
transformed parameters {
  vector[L] league_intensity =
    sigma_league_intensity *
    (z_league_intensity - mean(z_league_intensity));
  vector[L] league_duration =
    sigma_league_duration *
    (z_league_duration - mean(z_league_duration));
  vector[T] attack =
    sigma_attack * (z_attack - mean(z_attack));
  vector[T] exposure =
    sigma_exposure * (z_exposure - mean(z_exposure));
  vector[T] team_duration =
    sigma_team_duration *
    (z_team_duration - mean(z_team_duration));
}
model {
  alpha_intensity ~ normal(log(0.4), 0.5);
  alpha_duration ~ normal(log(32), 0.25);
  beta_intensity ~ normal(0, 0.25);
  beta_duration ~ normal(0, 0.15);
  z_league_intensity ~ std_normal();
  z_league_duration ~ std_normal();
  z_attack ~ std_normal();
  z_exposure ~ std_normal();
  z_team_duration ~ std_normal();
  sigma_league_intensity ~ normal(0, 0.2);
  sigma_league_duration ~ normal(0, 0.12);
  sigma_attack ~ normal(0, 0.2);
  sigma_exposure ~ normal(0, 0.2);
  sigma_team_duration ~ normal(0, 0.12);
  sigma_duration ~ normal(0, 0.2);
  phi ~ gamma(2, 0.2);

  for (n in 1:N) {
    real duration_eta =
      alpha_duration +
      league_duration[league[n]] +
      team_duration[blue_team[n]] +
      team_duration[red_team[n]] +
      X_duration[n] * beta_duration;
    real blue_eta =
      alpha_intensity +
      league_intensity[league[n]] +
      attack[blue_team[n]] +
      exposure[red_team[n]] +
      X_intensity[n] * beta_intensity;
    real red_eta =
      alpha_intensity +
      league_intensity[league[n]] +
      attack[red_team[n]] +
      exposure[blue_team[n]] +
      X_intensity[n] * beta_intensity;
    target += observation_weight[n] *
      lognormal_lpdf(duration[n] | duration_eta, sigma_duration);
    target += observation_weight[n] *
      neg_binomial_2_log_lpmf(
        blue_kills[n] |
        blue_eta + log(duration[n]),
        phi
      );
    target += observation_weight[n] *
      neg_binomial_2_log_lpmf(
        red_kills[n] |
        red_eta + log(duration[n]),
        phi
      );
  }
}
generated quantities {
  array[M] int<lower=0> y_pred;
  vector<lower=0>[M] duration_pred;
  vector<lower=0>[M] intensity_pred;
  for (m in 1:M) {
    real duration_eta =
      alpha_duration +
      league_duration[league_pred[m]] +
      team_duration[blue_team_pred[m]] +
      team_duration[red_team_pred[m]] +
      X_duration_pred[m] * beta_duration;
    real blue_eta =
      alpha_intensity +
      league_intensity[league_pred[m]] +
      attack[blue_team_pred[m]] +
      exposure[red_team_pred[m]] +
      X_intensity_pred[m] * beta_intensity;
    real red_eta =
      alpha_intensity +
      league_intensity[league_pred[m]] +
      attack[red_team_pred[m]] +
      exposure[blue_team_pred[m]] +
      X_intensity_pred[m] * beta_intensity;
    duration_pred[m] = lognormal_rng(
      duration_eta,
      sigma_duration
    );
    intensity_pred[m] = exp(blue_eta) + exp(red_eta);
    y_pred[m] =
      neg_binomial_2_log_rng(
        blue_eta + log(duration_pred[m]),
        phi
      ) +
      neg_binomial_2_log_rng(
        red_eta + log(duration_pred[m]),
        phi
      );
  }
}
