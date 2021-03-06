// Space time
#include <TMB.hpp>
// Function for detecting NAs
template<class Type>
bool isNA(Type x){
  return R_IsNA(asDouble(x));
}

// dlognorm
template<class Type>
Type dlognorm(Type x, Type log_mean, Type log_sd, int give_log=false){
  Type Return;
  if(give_log==false) Return = dnorm( log(x), log_mean, exp(log_sd), false) / x;
  if(give_log==true) Return = dnorm( log(x), log_mean, exp(log_sd), true) - log(x);
  return Return;
}

// The Poisson lognormal distribution.
// Bulmer, M. G. 1974. On fitting the Poisson lognormal distribution to species-
//   abundance data. Biometrics, 30: 101-110.
// \mu = mean; \sigma^2 = lognormal variance = \mu + \mu^2 * (exp(\sigma^2) - 1)
// where the variance of a negative binomial distribution is
// \sigma^2 = \mu + (\mu^2 / k)
// The Poisson distribution = \frac{\lambda^x * exp(-\lambda)}{x!}
// The Normal distribution = \frac{1}{sqrt{2*\sigma^2*\pie}} * exp(\frac{-(x-\mu)^2}{2*\sigma^2})
// p(x) = \frac{1}{sqrt{2*\sigma^2*\pie}*x!}
//   \integral{exp(-\lambda) * lambda^{x-1} * exp(-\frac{(ln(\lambda) - x)^2}{2 * \sigma^2})}dx
template<class Type>
Type d_poisson_lognormal(Type x, Type log_mean, Type log_sd, Type log_clustersize, int give_log=false){
  Type Return;
  Type log_notencounterprob = -1 * exp(log_mean) / exp(log_clustersize);
  Type encounterprob = 1 - exp( log_notencounterprob );
  if( x==0 ){
    Return = log_notencounterprob;
  }else{
    Return = log(encounterprob) + dlognorm( x, log_mean-log(encounterprob), log_sd, true );
  }
  if( give_log==true){ return Return; }else{ return exp(Return); }
}

template<class Type>
Type objective_function<Type>::operator() ()
{
  // Options
  DATA_IVECTOR( Options_vec );
  // Slot 0:  Observation model (0=Poisson;  1=Poisson-lognormal)

  // Indices
  DATA_INTEGER( n_i );         // Total number of observations
  DATA_INTEGER( n_x );         // Number of vertices in SPDE mesh
  DATA_INTEGER( n_t );         // Number of years
  DATA_INTEGER( n_p );         // Number of columns in covariate matrix X

  // Data
  DATA_IVECTOR( x_s );	      // Association of each station with a given vertex in SPDE mesh
  DATA_VECTOR( c_i );       	// Count data
  DATA_IVECTOR( t_i );        // Time for each sample
  DATA_MATRIX( X_xp );		    // Covariate design matrix

  // SPDE objects
  DATA_SPARSE_MATRIX(G0);
  DATA_SPARSE_MATRIX(G1);
  DATA_SPARSE_MATRIX(G2);

  // Fixed effects
  PARAMETER_VECTOR(alpha);   // Mean of Gompertz-drift field
  PARAMETER(phi);            // Offset of beginning from equilibrium
  PARAMETER(log_tau_E);      // log-inverse SD of Epsilon
  PARAMETER(log_tau_O);      // log-inverse SD of Omega
  PARAMETER(log_kappa);      // Controls range of spatial variation
  PARAMETER(rho);            // Autocorrelation (i.e. density dependence)
  PARAMETER_VECTOR(theta_z); // Parameters governing measurement error

  // Random effects
  PARAMETER_ARRAY(Epsilon_input);  // Spatial process variation
  PARAMETER_VECTOR(Omega_input);   // Spatial variation in carrying capacity

  // objective function -- joint negative log-likelihood
  using namespace density;
  Type jnll = 0;
  vector<Type> jnll_comp(3);
  jnll_comp.setZero();

  // Spatial parameters
  Type kappa2 = exp(2.0*log_kappa);
  Type kappa4 = kappa2*kappa2;
  Type pi = 3.141592;
  Type Range = sqrt(8) / exp( log_kappa );
  Type SigmaE = 1 / sqrt(4*pi*exp(2*log_tau_E)*exp(2*log_kappa));
  Type SigmaO = 1 / sqrt(4*pi*exp(2*log_tau_O)*exp(2*log_kappa));
  Eigen::SparseMatrix<Type> Q = kappa4*G0 + Type(2.0)*kappa2*G1 + G2;

  // Objects for derived values
  vector<Type> eta_x(n_x);
  vector<Type> Omega_x(n_x);
  vector<Type> Equil_x(n_x);
  vector<Type> log_chat_i(n_i);
  matrix<Type> Epsilon_xt(n_x, n_t);

  // Probability of Gaussian-Markov random fields (GMRFs)
  // jnll_comp(0) += GMRF(Q)(Omega_input);
  // If you do not scale below using Omega_x then you can scale here.
  // jnll_comp(0) += GMRF(Q)(Omega_input);
  // Spatial-temporal process error
  // If using autoregressive model.
  // jnll_comp(1) = SEPARABLE(AR1(rho),GMRF(Q))(Epsilon_input);
  // If using a recursive model
  jnll_comp(0) += GMRF(Q)(Omega_input);
  for(int t=0; t<n_t; t++){
    // code from spatial_index_model_V1
    // jnll_comp(1) += SCALE(GMRF(Q), 1/exp(log_tau_E))( Epsilon_input.col(t)-Epsilon_input.col(t-1));

    jnll_comp(1) += GMRF(Q)(Epsilon_input.col(t));
  }

  // Transform GMRFs
  // alpha parameter input is a single value, which is then repeated the same length as the
  // design matrix. Theoretically, alpha is the mean of the productivity field and should be
  // a single value. In the future one may want to look at how using a covariate design matrix
  // based on estimated management units could improve the ability of the model to estimate
  // other parameters.
  // The OM uses the log input mean density and calculates alpha
  // \alpha = ln(\bar{density}) * (1 - \rho).
  // Here, we do the opposite to calculate the equilibrium for each location on the mesh.
  eta_x = X_xp * alpha.matrix();
  for(int x=0; x<n_x; x++){
    Omega_x(x) = Omega_input(x) / exp(log_tau_O);
    Equil_x(x) = ( eta_x(x) + Omega_x(x) ) / (1-rho);
    for( int t=0; t<n_t; t++){
      Epsilon_xt(x,t) = Epsilon_input(x,t) / exp(log_tau_E);
    }
  }

  // Likelihood contribution from observations
  vector<Type> jnll_i(n_i);
  jnll_i.setZero();
  for (int i=0; i<n_i; i++){
    // t_i(i) is actually the timestep - 1 b/c indexing starts at zero
    // rho^0 == 1, and thus the population starts at phi
    if (t_i(i) == 0) log_chat_i(i) = phi + Equil_x(x_s(i)) + Epsilon_xt(x_s(i),t_i(i));
    if (t_i(i) > 0)  log_chat_i(i) = rho * log_chat_i(i - 1) + (eta_x(x_s(i)) + Omega_x(x_s(i))) + Epsilon_xt(x_s(i),t_i(i));
    if( !isNA(c_i(i)) ){
      if(Options_vec(0)==0) jnll_i(i) -= dpois( c_i(i), exp(log_chat_i(i)), true );
      if(Options_vec(0)==1) jnll_i(i) -= d_poisson_lognormal( c_i(i), log_chat_i(i), theta_z(0), theta_z(1), true );
    }
  }
  jnll_comp(2) = jnll_i.sum();
  jnll = jnll_comp.sum();
  // jnll = jnll_comp(1) + jnll_comp(2);

  // Diagnostics
  REPORT( jnll_comp );
  REPORT( jnll );
  // Spatial field summaries
  REPORT( Range );
  REPORT( SigmaE );
  REPORT( SigmaO );
  REPORT( rho );
  ADREPORT( Range );
  ADREPORT( SigmaE );
  ADREPORT( SigmaO );
  // Fields
  REPORT( Epsilon_xt );
  REPORT( Omega_x );
  REPORT( Equil_x );
  // Diagnostics
  REPORT( log_chat_i );
  REPORT( jnll_i );
  REPORT( theta_z );
  REPORT(x_s);
  REPORT(c_i);
  REPORT(t_i);
  REPORT(alpha);
  REPORT(phi);
  REPORT(log_tau_E);
  REPORT(log_tau_O);
  REPORT(log_kappa);
  REPORT(eta_x);

  return jnll;
}

