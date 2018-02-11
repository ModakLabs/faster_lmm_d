/*
   This code is part of faster_lmm_d and published under the GPLv3
   License (see LICENSE.txt)

   Copyright © 2017-2018 Prasun Anand & Pjotr Prins
*/

module faster_lmm_d.mvlmm;

import core.stdc.stdlib : exit;

import std.conv;
import std.exception;
import std.file;
import std.math;
import std.parallelism;
alias mlog = std.math.log;
import std.process;
import std.range;
import std.stdio;
import std.typecons;
import std.experimental.logger;
import std.string;

import faster_lmm_d.dmatrix;
import faster_lmm_d.gemma_lmm;
import faster_lmm_d.gemma_param;
import faster_lmm_d.helpers;
import faster_lmm_d.optmatrix;

import gsl.permutation;
import gsl.cdf;

// Results for mvLMM.
struct MPHSUMSTAT {
  double[] v_beta;  // REML estimator for beta.
  double p_wald;          // p value from a Wald test.
  double p_lrt;           // p value from a likelihood ratio test.
  double p_score;         // p value from a score test.
  double[] v_Vg;    // Estimator for Vg, right half.
  double[] v_Ve;    // Estimator for Ve, right half.
  double[] v_Vbeta; // Estimator for Vbeta, right half.
};


void analyze_bimbam_mvlmm(const DMatrix U, const DMatrix eval,
                          const DMatrix UtW, const DMatrix UtY, string file_geno) {

  MPHSUMSTAT[] sumStat;
  string filename = file_geno;
  auto pipe = pipeShell("gunzip -c " ~ filename);
  File input = pipe.stdout;

  string ch_ptr;

  double logl_H0 = 0.0, logl_H1 = 0.0, p_wald = 0, p_lrt = 0, p_score = 0;
  double crt_a, crt_b, crt_c;
  int n_miss, c_phen;
  double geno, x_mean;
  size_t c = 0;
  size_t n_size = UtY.shape[0], d_size = UtY.shape[1], c_size = UtW.shape[1];

  size_t dc_size = d_size * (c_size + 1), v_size = d_size * (d_size + 1) / 2;

  // Create a large matrix.
  size_t LMM_BATCH_SIZE = 2000;
  size_t msize = LMM_BATCH_SIZE;
  DMatrix Xlarge = zeros_dmatrix(U.shape[0], msize);
  DMatrix UtXlarge; // = gsl_matrix_alloc(U.shape[0], msize);
  //gsl_matrix_set_zero(Xlarge);

  // Large matrices for EM.
  DMatrix U_hat;    //= gsl_matrix_alloc(d_size, n_size);
  DMatrix E_hat;    //= gsl_matrix_alloc(d_size, n_size);
  DMatrix OmegaU;   //= gsl_matrix_alloc(d_size, n_size);
  DMatrix OmegaE;   //= gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiY;   //= gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiBX;    //= gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiU;   //= gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiE;   //= gsl_matrix_alloc(d_size, n_size);

  // Large matrices for NR.
  // Each dxd block is H_k^{-1}.
  DMatrix Hi_all;   //= gsl_matrix_alloc(d_size, d_size * n_size);

  // Each column is H_k^{-1}y_k.
  DMatrix Hiy_all;    //= gsl_matrix_alloc(d_size, n_size);

  // Each dcxdc block is x_k \otimes H_k^{-1}.
  DMatrix xHi_all;    //= gsl_matrix_alloc(dc_size, d_size * n_size);
  DMatrix Hessian;    //= gsl_matrix_alloc(v_size * 2, v_size * 2);

  DMatrix x;    // = gsl_vector_alloc(n_size);
  DMatrix x_miss;   // = gsl_vector_alloc(n_size);

  DMatrix Y;    //= gsl_matrix_alloc(d_size, n_size);
  DMatrix X;    //= gsl_matrix_alloc(c_size + 1, n_size);
  DMatrix V_g;    //= gsl_matrix_alloc(d_size, d_size);
  DMatrix V_e;    //= gsl_matrix_alloc(d_size, d_size);
  DMatrix B;    //= gsl_matrix_alloc(d_size, c_size + 1);
  DMatrix beta;   // = gsl_vector_alloc(d_size);
  DMatrix Vbeta;    //= gsl_matrix_alloc(d_size, d_size);

  // Null estimates for initial values.
  DMatrix V_g_null;   //= gsl_matrix_alloc(d_size, d_size);
  DMatrix V_e_null;   //= gsl_matrix_alloc(d_size, d_size);
  DMatrix B_null;   //= gsl_matrix_alloc(d_size, c_size + 1);
  DMatrix se_B_null;    //= gsl_matrix_alloc(d_size, c_size);

  //gsl_matrix_view
  DMatrix X_sub = get_sub_dmatrix(X, 0, 0, c_size, n_size);
  //gsl_matrix_view
  DMatrix B_sub = get_sub_dmatrix(B, 0, 0, d_size, c_size);

  //gsl_matrix_view
  DMatrix xHi_all_sub = get_sub_dmatrix(xHi_all, 0, 0, d_size * c_size, d_size * n_size);

  //gsl_matrix_transpose_memcpy(Y, UtY);

  Y = UtY.T;

  //gsl_matrix_transpose_memcpy(X_sub, UtW);
  X_sub = UtW.T;

  //gsl_vector_view
  DMatrix X_row = get_row(X, c_size);
  //gsl_vector_set_zero(X_row);

  //gsl_vector_view
  DMatrix B_col = get_col(B, c_size);
  //gsl_vector_set_zero(B_col);

  size_t em_iter = 0; //check
  double em_prec = 0;
  size_t nr_iter = 0;
  double nr_prec = 0;
  double l_min = 0;
  double l_max = 0;
  size_t n_region;
  double[] Vg_remle_null;
  double[] Ve_remle_null;
  double[] VVg_remle_null;
  double[] VVe_remle_null;
  double[] beta_remle_null;
  double[] se_beta_remle_null;
  double logl_remle_H0;

  double[] Vg_mle_null;
  double[] Ve_mle_null;
  double[] VVg_mle_null;
  double[] VVe_mle_null;
  double[] beta_mle_null;
  double[] se_beta_mle_null;
  double logl_mle_H0;
  int[] indicator_snp;
  int[] indicator_idv;
  int a_mode;
  size_t ni_test, ni_total;


  MphInitial(em_iter, em_prec, nr_iter, nr_prec, eval, X_sub, Y, l_min, l_max, n_region, V_g, V_e, B_sub);
  logl_H0 = MphEM('R', em_iter, em_prec, eval, X_sub, Y, U_hat, E_hat, OmegaU,
                    OmegaE, UltVehiY, UltVehiBX, UltVehiU, UltVehiE, V_g, V_e, B_sub);
  logl_H0 = MphNR('R', nr_iter, nr_prec, eval, X_sub, Y, Hi_all, xHi_all_sub, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
  MphCalcBeta(eval, X_sub, Y, V_g, V_e, UltVehiY, B_sub, se_B_null);

  c = 0;
  Vg_remle_null = [];
  Ve_remle_null = [];
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      Vg_remle_null ~= V_g.accessor(i, j);
      Ve_remle_null ~= V_e.accessor(i, j);
      //cpar params
      VVg_remle_null ~= Hessian.accessor(c, c);
      VVe_remle_null ~= Hessian.accessor(c + v_size, c + v_size);
      c++;
    }
  }
  beta_remle_null = [];
  se_beta_remle_null = [];
  for (size_t i = 0; i < se_B_null.shape[0]; i++) {
    for (size_t j = 0; j < se_B_null.shape[1]; j++) {
      beta_remle_null ~= B.accessor(i, j);
      se_beta_remle_null ~= se_B_null.accessor(i, j);
    }
  }
  logl_remle_H0 = logl_H0;

  writeln("REMLE estimate for Vg in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_g.accessor(i, j), "\t");
    }
    write("\n");
  }

  writeln("se(Vg): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(Hessian.accessor(c, c), "\t");
    }
    write("\n");
  }
  writeln("REMLE estimate for Ve in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_e.accessor(i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Ve): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c + v_size, c + v_size)), "\t");
    }
    write("\n");
  }
  writeln("REMLE likelihood = ", logl_H0);

  logl_H0 = MphEM('L', em_iter, em_prec, eval, X_sub, Y, U_hat, E_hat,
                  OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU, UltVehiE, V_g,
                  V_e, B_sub);
  logl_H0 = MphNR('L', nr_iter, nr_prec, eval, X_sub, Y, Hi_all,
                  xHi_all_sub, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b,
                  crt_c);
  MphCalcBeta(eval, X_sub, Y, V_g, V_e, UltVehiY, B_sub, se_B_null);

  c = 0;
  Vg_mle_null = [];
  Ve_mle_null = [];
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      Vg_mle_null ~= V_g.accessor(i, j);
      Ve_mle_null ~= V_e.accessor(i, j);
      VVg_mle_null ~= Hessian.accessor(c, c);
      VVe_mle_null ~= Hessian.accessor(c + v_size, c + v_size);
      c++;
    }
  }
  beta_mle_null = [];
  se_beta_mle_null = [];
  for (size_t i = 0; i < se_B_null.shape[0]; i++) {
    for (size_t j = 0; j < se_B_null.shape[1]; j++) {
      beta_mle_null ~= B.accessor(i, j);
      se_beta_mle_null ~= se_B_null.accessor(i, j);
    }
  }
  logl_mle_H0 = logl_H0;

  writeln("MLE estimate for Vg in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_g.accessor(i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Vg): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c, c)), "\t");
    }
    write("\n");
  }
  writeln("MLE estimate for Ve in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_e.accessor(i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Ve): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c + v_size, c + v_size)), "\t");
    }
    write("\n");
  }
  writeln("MLE likelihood = ", logl_H0);
  double[] v_beta, v_Vg, v_Ve, v_Vbeta;
  for (size_t i = 0; i < d_size; i++) {
    v_beta ~= 0;
  }
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      v_Vg ~= 0;
      v_Ve ~= 0;
      v_Vbeta ~= 0;
    }
  }

  V_g_null = V_g;
  V_e_null = V_e;
  B_null = B;

  // Start reading genotypes and analyze.
  size_t csnp = 0, t_last = 0;
  for (size_t t = 0; t < indicator_snp.length; ++t) {
    if (indicator_snp[t] == 0) {
      continue;
    }
    t_last++;
  }
  int t = 0;
  foreach (line ; input.byLine) {

    if (indicator_snp[t] == 0) {
      t++;
      continue;
    }

    //ch_ptr = strtok_safe((char *)line.c_str(), " , \t");
    //ch_ptr = strtok_safe(NULL, " , \t");
    //ch_ptr = strtok_safe(NULL, " , \t");

    x_mean = 0.0;
    c_phen = 0;
    n_miss = 0;
    //gsl_vector_set_zero(x_miss);
    auto chr = to!string(line).split(",");
    for (size_t i = 0; i < ni_total; ++i) {
      ch_ptr = chr[i];
      if (indicator_idv[i] == 0) {
        continue;
      }

      if (ch_ptr == "NA") {
        x_miss.elements[c_phen] = 0.0;
        n_miss++;
      } else {
        geno = to!double(ch_ptr);

        x.elements[c_phen] = geno;
        x_miss.elements[c_phen] = 1.0;
        x_mean += geno;
      }
      c_phen++;
    }

    x_mean /= to!double(ni_test - n_miss);

    for (size_t i = 0; i < ni_test; ++i) {
      if (x_miss.elements[i] == 0) {
        x.elements[i] = x_mean;
      }
      geno = x.elements[i];
    }

    DMatrix Xlarge_col = get_col(Xlarge, csnp % msize);
    //gsl_vector_memcpy(Xlarge_col, x);
    csnp++;

    if (csnp % msize == 0 || csnp == t_last) {
      size_t l = 0;
      if (csnp % msize == 0) {
        l = msize;
      } else {
        l = csnp % msize;
      }

      //gsl_matrix_view
      DMatrix Xlarge_sub =
          get_sub_dmatrix(Xlarge, 0, 0, Xlarge.shape[0], l);
      //gsl_matrix_view
      DMatrix UtXlarge_sub =
          get_sub_dmatrix(UtXlarge, 0, 0, UtXlarge.shape[0], l);

      UtXlarge_sub = matrix_mult(U.T, Xlarge_sub);

      //gsl_matrix_set_zero(Xlarge);
      Xlarge = zeros_dmatrix(Xlarge.shape[0], Xlarge.shape[1]);

      for (size_t i = 0; i < l; i++) {
        //gsl_vector_view
        DMatrix UtXlarge_col = get_col(UtXlarge, i);
        //gsl_vector_memcpy(X_row, UtXlarge_col);

        // Initial values.
        V_g = V_g_null;
        V_e = V_e_null;
        B = B_null;

        // 3 is before 1.
        //set Values
        double p_nr, crt;

        if (a_mode == 3 || a_mode == 4) {
          p_score = MphCalcP(eval, X_row, X_sub, Y, V_g_null,
                             V_e_null, UltVehiY, beta, Vbeta);
          if (p_score < p_nr && crt == 1) {
            logl_H1 = MphNR('R', 1, nr_prec * 10, eval, X, Y, Hi_all, xHi_all,
                            Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
            p_score = PCRT(3, d_size, p_score, crt_a, crt_b, crt_c);
          }
        }

        if (a_mode == 2 || a_mode == 4) {
          logl_H1 = MphEM('L', em_iter / 10, em_prec * 10, eval, X, Y, U_hat,
                          E_hat, OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU,
                          UltVehiE, V_g, V_e, B);

          // Calculate beta and Vbeta.
          p_lrt = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);
          p_lrt = gsl_cdf_chisq_Q(2.0 * (logl_H1 - logl_H0), to!double(d_size));

          if (p_lrt < p_nr) {
            logl_H1 =
                MphNR('L', nr_iter / 10, nr_prec * 10, eval, X, Y, Hi_all,
                      xHi_all, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);

            // Calculate beta and Vbeta.
            p_lrt = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);
            p_lrt = gsl_cdf_chisq_Q(2.0 * (logl_H1 - logl_H0), to!double(d_size));

            if (crt == 1) {
              p_lrt = PCRT(2, d_size, p_lrt, crt_a, crt_b, crt_c);
            }
          }
        }

        if (a_mode == 1 || a_mode == 4) {
          logl_H1 = MphEM('R', em_iter / 10, em_prec * 10, eval, X, Y, U_hat,
                          E_hat, OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU,
                          UltVehiE, V_g, V_e, B);
          p_wald = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);

          if (p_wald < p_nr) {
            logl_H1 = MphNR('R', nr_iter / 10, nr_prec * 10, eval, X, Y, Hi_all,
                            xHi_all, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
            p_wald = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);

            if (crt == 1) {
              p_wald = PCRT(1, d_size, p_wald, crt_a, crt_b, crt_c);
            }
          }
        }

        // Store summary data.
        for (size_t k = 0; k < d_size; k++) {
          v_beta[k] = beta.elements[k];
        }

        c = 0;
        for (size_t k = 0; k < d_size; k++) {
          for (size_t j = k; j < d_size; j++) {
            v_Vg[c] = V_g.accessor(k, j);
            v_Ve[c] = V_e.accessor(k, j);
            v_Vbeta[c] = Vbeta.accessor(k, j);
            c++;
          }
        }

        MPHSUMSTAT SNPs = {v_beta, p_wald, p_lrt, p_score, v_Vg, v_Ve, v_Vbeta};
        sumStat ~= SNPs;
      }
    }

    t++;
  }
  return;
}

// Initialize Vg, Ve and B.
void MphInitial(const size_t em_iter, const double em_prec,
                const size_t nr_iter, const double nr_prec,
                const DMatrix eval, const DMatrix X, const DMatrix Y,
                const double l_min, const double l_max, const size_t n_region,
                DMatrix V_g, DMatrix V_e, DMatrix B) {

  V_g = zeros_dmatrix(V_g.shape[0], V_g.shape[1]);
  V_e = zeros_dmatrix(V_e.shape[0], V_e.shape[1]);
  B   = zeros_dmatrix(B.shape[0], B.shape[1]);

  size_t n_size = eval.elements.length, c_size = X.shape[0], d_size = Y.shape[0];
  double a, b, c;
  double lambda, logl, vg, ve;

  // Initialize the diagonal elements of Vg and Ve using univariate
  // LMM and REML estimates.
  DMatrix Xt; //= gsl_matrix_alloc(n_size, c_size);
  DMatrix beta_temp; // = gsl_vector_alloc(c_size);
  DMatrix se_beta_temp; // = gsl_vector_alloc(c_size);

  Xt = X.T;

  for (size_t i = 0; i < d_size; i++) {
    //gsl_vector_const_view
    DMatrix Y_row = get_row(Y, i);
    CalcLambda('R', eval, Xt, Y_row, l_min, l_max, n_region, lambda, logl);
    //CalcLmmVgVeBeta(eval, Xt, Y_row, lambda, vg, ve, beta_temp, se_beta_temp);

    V_g.set(i, i, vg);
    V_e.set(i, i, ve);
  }

  // If number of phenotypes is above four, then obtain the off
  // diagonal elements with two trait models.
  if (d_size > 4) {

    // First obtain good initial values.
    // Large matrices for EM.
    DMatrix U_hat; // = gsl_matrix_alloc(2, n_size);
    DMatrix E_hat; // = gsl_matrix_alloc(2, n_size);
    DMatrix OmegaU; // = gsl_matrix_alloc(2, n_size);
    DMatrix OmegaE; // = gsl_matrix_alloc(2, n_size);
    DMatrix UltVehiY; // = gsl_matrix_alloc(2, n_size);
    DMatrix UltVehiBX; // = gsl_matrix_alloc(2, n_size);
    DMatrix UltVehiU; // = gsl_matrix_alloc(2, n_size);
    DMatrix UltVehiE; // = gsl_matrix_alloc(2, n_size);

    // Large matrices for NR. Each dxd block is H_k^{-1}.
    DMatrix Hi_all; // = gsl_matrix_alloc(2, 2 * n_size);

    // Each column is H_k^{-1}y_k.
    DMatrix Hiy_all; // = gsl_matrix_alloc(2, n_size);

    // Each dcxdc block is x_k\otimes H_k^{-1}.
    DMatrix xHi_all; // = gsl_matrix_alloc(2 * c_size, 2 * n_size);
    DMatrix Hessian; // = gsl_matrix_alloc(6, 6);

    // 2 by n matrix of Y.
    DMatrix Y_sub; // = gsl_matrix_alloc(2, n_size);
    DMatrix Vg_sub; // = gsl_matrix_alloc(2, 2);
    DMatrix Ve_sub; // = gsl_matrix_alloc(2, 2);
    DMatrix B_sub; // = gsl_matrix_alloc(2, c_size);

    for (size_t i = 0; i < d_size; i++) {
      //gsl_vector_view
      DMatrix Y_sub1 = get_row(Y_sub, 0);
      //gsl_vector_const_view
      DMatrix Y_1 = get_row(Y, i);
      Y_sub1 = Y_1;

      for (size_t j = i + 1; j < d_size; j++) {
        //gsl_vector_view
        DMatrix Y_sub2 = get_row(Y_sub, 1);
        //gsl_vector_const_view
        DMatrix Y_2 = get_row(Y, j);
        Y_sub2 = Y_2;

        Vg_sub = zeros_dmatrix(Vg_sub.shape[0], Vg_sub.shape[1]);
        //gsl_matrix_set_zero(Ve_sub);
        Ve_sub = zeros_dmatrix(Ve_sub.shape[0], Ve_sub.shape[1]);
        Vg_sub.set(0, 0, V_g.accessor(i, i));
        Ve_sub.set(0, 0, V_e.accessor(i, i));
        Vg_sub.set(1, 1, V_g.accessor(j, j));
        Ve_sub.set(1, 1, V_e.accessor(j, j));

        logl = MphEM('R', em_iter, em_prec, eval, X, Y_sub, U_hat, E_hat,
                     OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU, UltVehiE,
                     Vg_sub, Ve_sub, B_sub);
        logl = MphNR('R', nr_iter, nr_prec, eval, X, Y_sub, Hi_all, xHi_all,
                     Hiy_all, Vg_sub, Ve_sub, Hessian, a, b, c);

        V_g.set(i, j, Vg_sub.accessor(0, 1));
        V_g.set(j, i, Vg_sub.accessor(0, 1));

        V_e.set(i, j, Ve_sub.accessor(0, 1));
        V_e.set(j, i, Ve_sub.accessor(0, 1));
      }
    }
  }

  // Calculate B hat using GSL estimate.
  DMatrix UltVehiY; // = gsl_matrix_alloc(d_size, n_size);

  DMatrix D_l; // = gsl_vector_alloc(d_size);
  DMatrix UltVeh; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehi; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix Qi; // = gsl_matrix_alloc(d_size * c_size, d_size * c_size);
  DMatrix XHiy; // = gsl_vector_alloc(d_size * c_size);
  DMatrix beta; // = gsl_vector_alloc(d_size * c_size);

  XHiy = zeros_dmatrix(XHiy.shape[0], XHiy.shape[1]);

  double dl, d, delta, dx, dy;

  // Eigen decomposition and calculate log|Ve|.
  // double logdet_Ve = EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);
  EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);

  // Calculate Qi and log|Q|.
  // double logdet_Q = CalcQi(eval, D_l, X, Qi);
  CalcQi(eval, D_l, X, Qi);

  // Calculate UltVehiY.
  UltVehiY =  matrix_mult(UltVehi, Y).elements[0];

  // calculate XHiy
  for (size_t i = 0; i < d_size; i++) {
    dl = D_l.elements[i];

    for (size_t j = 0; j < c_size; j++) {
      d = 0.0;
      for (size_t k = 0; k < n_size; k++) {
        delta = eval.elements[k];
        dx = X.accessor(j, k);
        dy = UltVehiY.accessor(i, k);
        d += dy * dx / (delta * dl + 1.0);
      }
      XHiy.elements[j * d_size + i] = d;
    }
  }

  beta = matrix_mult(Qi, XHiy);

  // Multiply beta by UltVeh and save to B.
  for (size_t i = 0; i < c_size; i++) {
    //gsl_vector_view
    DMatrix B_col = get_col(B, i);
    //gsl_vector_view
    DMatrix beta_sub;// = gsl_vector_subvector(beta, i * d_size, d_size);
    B_col = matrix_mult(UltVeh.T, beta_sub);
    B_col = matrix_mult(beta_sub, UltVeh);
  }

  // Free memory.

  return;
}

size_t GetIndex(const size_t i, const size_t j, const size_t d_size) {
  if (i >= d_size || j >= d_size) {
    writeln("error in GetIndex.");
    return 0;
  }

  size_t s, l;
  if (j < i) {
    s = j;
    l = i;
  } else {
    s = i;
    l = j;
  }
  return (2 * d_size - s + 1) * s / 2 + l - s;
}

double MphEM(const char func_name, const size_t max_iter, const double max_prec,
             const DMatrix eval, const DMatrix X, const DMatrix Y,
             DMatrix U_hat, DMatrix E_hat, DMatrix OmegaU,
             DMatrix OmegaE, DMatrix UltVehiY, DMatrix UltVehiBX,
             DMatrix UltVehiU, DMatrix UltVehiE, DMatrix V_g,
             DMatrix V_e, DMatrix B) {
  if (func_name != 'R' && func_name != 'L' && func_name != 'r' && func_name != 'l') {
    writeln("func_name only takes 'R' or 'L': 'R' for log-restricted likelihood, 'L' for log-likelihood.");
    return 0.0;
  }

  size_t n_size = eval.size, c_size = X.shape[0], d_size = Y.shape[0];
  size_t dc_size = d_size * c_size;

  DMatrix XXt; // = gsl_matrix_alloc(c_size, c_size);
  DMatrix XXti; // = gsl_matrix_alloc(c_size, c_size);
  DMatrix D_l; // = gsl_vector_alloc(d_size);
  DMatrix UltVeh; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehi; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehiB; // = gsl_matrix_alloc(d_size, c_size);
  DMatrix Qi; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix Sigma_uu; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix Sigma_ee; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix xHiy; // = gsl_vector_alloc(dc_size);
  gsl_permutation pmt = gsl_permutation_alloc(c_size);

  double logl_const = 0.0, logl_old = 0.0, logl_new = 0.0;
  double logdet_Q, logdet_Ve;
  int sig;

  // Calculate |XXt| and (XXt)^{-1}.
  gsl_blas_dsyrk(CblasUpper, CblasNoTrans, 1.0, X, 0.0, XXt);
  for (size_t i = 0; i < c_size; ++i) {
    for (size_t j = 0; j < i; ++j) {
      XXt.set(i, j, XXt.accessor(j, i));
    }
  }

  LUDecomp(XXt, pmt, &sig);
  LUInvert(XXt, pmt, XXti);

  // Calculate the constant for logl.
  if (func_name == 'R' || func_name == 'r') {
    logl_const =
        -0.5 * to!double(n_size - c_size) * to!double(d_size) * mlog(2.0 * PI) +
        0.5 * to!double(d_size) * LULndet(XXt);
  } else {
    logl_const = -0.5 * to!double(n_size) * to!double(d_size) * mlog(2.0 * PI);
  }

  // Start EM.
  for (size_t t = 0; t < max_iter; t++) {
    logdet_Ve = EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);

    logdet_Q = CalcQi(eval, D_l, X, Qi);

    UltVehiY = matrix_mult(UltVehi, Y);
    CalcXHiY(eval, D_l, X, UltVehiY, xHiy);

    // Calculate log likelihood/restricted likelihood value, and
    // terminate if change is small.
    logl_new = logl_const + MphCalcLogL(eval, xHiy, D_l, UltVehiY, Qi) -
               0.5 * to!double(n_size) * logdet_Ve;
    if (func_name == 'R' || func_name == 'r') {
      logl_new += -0.5 * (logdet_Q - to!double(c_size) * logdet_Ve);
    }
    if (t != 0 && abs(logl_new - logl_old) < max_prec) {
      break;
    }
    logl_old = logl_new;

    CalcOmega(eval, D_l, OmegaU, OmegaE);

    // Update UltVehiB, UltVehiU.
    if (func_name == 'R' || func_name == 'r') {
      UpdateRL_B(xHiy, Qi, UltVehiB);
      UltVehiBX = matrix_mult(UltVehiB, X);
    } else if (t == 0) {
      UltVehiB = matrix_mult(UltVehi, B);
      UltVehiBX = matrix_mult(UltVehiB, X);
    }

    UpdateU(OmegaE, UltVehiY, UltVehiBX, UltVehiU);

    if (func_name == 'L' || func_name == 'l') {

      // UltVehiBX is destroyed here.
      UpdateL_B(X, XXti, UltVehiY, UltVehiU, UltVehiBX, UltVehiB);
      UltVehiBX = matrix_mult(UltVehiB, X);
    }

    UpdateE(UltVehiY, UltVehiBX, UltVehiU, UltVehiE);

    // Calculate U_hat, E_hat and B.
    U_hat = matrix_mult(UltVeh, UltVehiU);
    E_hat = matrix_mult(UltVeh, UltVehiE);
    B = matrix_mult(UltVeh, UltVehiB);

    // Calculate Sigma_uu and Sigma_ee.
    CalcSigma(func_name, eval, D_l, X, OmegaU, OmegaE, UltVeh, Qi, Sigma_uu,
              Sigma_ee);

    // Update V_g and V_e.
    UpdateV(eval, U_hat, E_hat, Sigma_uu, Sigma_ee, V_g, V_e);
  }

  gsl_permutation_free(pmt);

  return logl_new;
}

double MphNR(const char func_name, const size_t max_iter, const double max_prec,
             const DMatrix eval, const DMatrix X, const DMatrix Y,
             DMatrix Hi_all, DMatrix xHi_all, DMatrix Hiy_all,
             DMatrix V_g, DMatrix V_e, DMatrix Hessian_inv,
             double crt_a, double crt_b, double crt_c) {
  if (func_name != 'R' && func_name != 'L' && func_name != 'r' && func_name != 'l') {
    writeln("func_name only takes 'R' or 'L': 'R' for log-restricted likelihood, 'L' for log-likelihood.");
    return 0.0;
  }
  size_t n_size = eval.size, c_size = X.shape[0], d_size = Y.shape[0];
  size_t dc_size = d_size * c_size;
  size_t v_size = d_size * (d_size + 1) / 2;

  double logdet_H, logdet_Q, yPy, logl_const;
  double logl_old = 0.0, logl_new = 0.0, step_scale;
  int sig;
  size_t step_iter, flag_pd;

  DMatrix Vg_save; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix Ve_save; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix V_temp; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix U_temp; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix D_temp; // = gsl_vector_alloc(d_size);
  DMatrix xHiy; // = gsl_vector_alloc(dc_size);
  DMatrix QixHiy; // = gsl_vector_alloc(dc_size);
  DMatrix Qi; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix XXt; // = gsl_matrix_alloc(c_size, c_size);

  DMatrix gradient; // = gsl_vector_alloc(v_size * 2);

  // Calculate |XXt| and (XXt)^{-1}.
  gsl_blas_dsyrk(CblasUpper, CblasNoTrans, 1.0, X, 0.0, XXt);
  for (size_t i = 0; i < c_size; ++i) {
    for (size_t j = 0; j < i; ++j) {
      XXt.set(i, j) = XXt.accessor(j, i);
    }
  }

  gsl_permutation pmt = gsl_permutation_alloc(c_size);
  LUDecomp(XXt, pmt, &sig);
  gsl_permutation_free(pmt);

  // Calculate the constant for logl.
  if (func_name == 'R' || func_name == 'r') {
    logl_const =
        -0.5 * to!double(n_size - c_size) * to!double(d_size) * mlog(2.0 * PI) +
        0.5 * to!double(d_size) * LULndet(XXt);
  } else {
    logl_const = -0.5 * to!double(n_size) * to!double(d_size) * mlog(2.0 * PI);
  }

  // Optimization iterations.
  for (size_t t = 0; t < max_iter; t++) {
    Vg_save = V_g; // Check dup
    Ve_save = V_e;

    step_scale = 1.0;
    step_iter = 0;
    do {
      V_g = Vg_save;
      V_e = Ve_save;

      // Update Vg, Ve, and invert Hessian.
      if (t != 0) {
        UpdateVgVe(Hessian_inv, gradient, step_scale, V_g, V_e);
      }

      // Check if both Vg and Ve are positive definite.
      flag_pd = 1;
      V_temp = V_e;
      EigenDecomp(V_temp, U_temp, D_temp, 0);
      for (size_t i = 0; i < d_size; i++) {
        if (D_temp.elements[i] <= 0) {
          flag_pd = 0;
        }
      }
      V_temp = V_g;
      EigenDecomp(V_temp, U_temp, D_temp, 0);
      for (size_t i = 0; i < d_size; i++) {
        if (D_temp.elements[i] <= 0) {
          flag_pd = 0;
        }
      }

      // If flag_pd==1, continue to calculate quantities
      // and logl.
      if (flag_pd == 1) {
        CalcHiQi(eval, X, V_g, V_e, Hi_all, Qi, logdet_H, logdet_Q);
        Calc_Hiy_all(Y, Hi_all, Hiy_all);
        Calc_xHi_all(X, Hi_all, xHi_all);

        // Calculate QixHiy and yPy.
        Calc_xHiy(Y, xHi_all, xHiy);
        QixHiy = matrix_mult(Qi, xHiy);

        yPy = vector_ddot(QixHiy, xHiy);
        yPy = Calc_yHiy(Y, Hiy_all) - yPy;

        // Calculate log likelihood/restricted likelihood value.
        if (func_name == 'R' || func_name == 'r') {
          logl_new = logl_const - 0.5 * logdet_H - 0.5 * logdet_Q - 0.5 * yPy;
        } else {
          logl_new = logl_const - 0.5 * logdet_H - 0.5 * yPy;
        }
      }

      step_scale /= 2.0;
      step_iter++;

    } while (
        (flag_pd == 0 || logl_new < logl_old || logl_new - logl_old > 10) &&
        step_iter < 10 && t != 0);

    // Terminate if change is small.
    if (t != 0) {
      if (logl_new < logl_old || flag_pd == 0) {
        V_g = Vg_save;  // Check dup
        V_e = Ve_save;
        break;
      }

      if (logl_new - logl_old < max_prec) {
        break;
      }
    }

    logl_old = logl_new;

    CalcDev(func_name, eval, Qi, Hi_all, xHi_all, Hiy_all, QixHiy, gradient, Hessian_inv, crt_a, crt_b, crt_c);
  }

  // Mutiply Hessian_inv with -1.0.
  // Now Hessian_inv is the variance matrix.
  Hessian_inv = multiply_dmatrix_num(Hessian_inv, -1.0);

  return logl_new;
}

// Calculate p-value, beta (d by 1 vector) and V(beta).
double MphCalcP(const DMatrix eval, const DMatrix x_vec, const DMatrix W,
                const DMatrix Y, const DMatrix V_g, const DMatrix V_e,
                DMatrix UltVehiY, DMatrix beta, DMatrix Vbeta) {
  size_t n_size = eval.elements.length, c_size = W.shape[0], d_size = V_g.shape[0];
  size_t dc_size = d_size * c_size;
  double delta, dl, d, d1, d2, dy, dx, dw; //  logdet_Ve, logdet_Q, p_value;

  DMatrix D_l; // = gsl_vector_alloc(d_size);
  DMatrix UltVeh; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehi; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix Qi; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix WHix; // = gsl_matrix_alloc(dc_size, d_size);
  DMatrix QiWHix; // = gsl_matrix_alloc(dc_size, d_size);

  DMatrix xPx; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix xPy; // = gsl_vector_alloc(d_size);
  DMatrix WHiy; // = gsl_vector_alloc(dc_size);

  //gsl_matrix_set_zero(xPx);
  //gsl_matrix_set_zero(WHix);
  //gsl_vector_set_zero(xPy);
  //gsl_vector_set_zero(WHiy);

  // Eigen decomposition and calculate log|Ve|.
  EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);

  // Calculate Qi and log|Q|.
  CalcQi(eval, D_l, W, Qi);

  // Calculate UltVehiY.
  UltVehiY = matrix_mult(UltVehi, Y);

  // Calculate WHix, WHiy, xHiy, xHix.
  for (size_t i = 0; i < d_size; i++) {
    dl = D_l.elements[i];

    d1 = 0.0;
    d2 = 0.0;
    for (size_t k = 0; k < n_size; k++) {
      delta = gsl_vector_get(eval, k);
      dx = x_vec.elements[k];
      dy = UltVehiY.accessor(i, k);

      d1 += dx * dy / (delta * dl + 1.0);
      d2 += dx * dx / (delta * dl + 1.0);
    }
    gsl_vector_set(xPy, i, d1);
    gsl_matrix_set(xPx, i, i, d2);

    for (size_t j = 0; j < c_size; j++) {
      d1 = 0.0;
      d2 = 0.0;
      for (size_t k = 0; k < n_size; k++) {
        delta = gsl_vector_get(eval, k);
        dx = x_vec.elements[k];
        dw = W.accessor(j, k);
        dy = UltVehiY.accessor(i, k);

        d1 += dx * dw / (delta * dl + 1.0);
        d2 += dy * dw / (delta * dl + 1.0);
      }
      WHix.set(j * d_size + i, i, d1);
      WHiy.set(j * d_size + i, d2);
    }
  }

  QiWHix = matrix_mult(Qi, WHix);
  xPx    = matrix_mult(WHix.T, QiWHix);
  xPy    = matrix_mult(QiWHix.T, WHiy, );

  // Calculate V(beta) and beta.
  int sig;
  gsl_permutation *pmt = gsl_permutation_alloc(d_size);
  LUDecomp(xPx, pmt, &sig);
  LUSolve(xPx, pmt, xPy, D_l);
  LUInvert(xPx, pmt, Vbeta);

  // Need to multiply UltVehi on both sides or one side.
  beta  = matrix_mult(UltVeh.T, D_l);
  xPx   = matrix_mult(Vbeta, UltVeh);
  Vbeta = matrix_mult(UltVeh.T, xPx);

  // Calculate test statistic and p value.
  d = vector_ddot(D_l, xPy);

  double p_value = gsl_cdf_chisq_Q(d, to!double(d_size));

  gsl_permutation_free(pmt);

  return p_value;
}

void MphCalcBeta(const DMatrix eval, const DMatrix W, const DMatrix Y, const DMatrix V_g,
                 const DMatrix V_e, DMatrix UltVehiY, DMatrix B, DMatrix se_B) {
  size_t n_size = eval.length, c_size = W.shape[0], d_size = W.shape[1];
  size_t dc_size = d_size * c_size;
  double delta, dl, d, dy, dw; // , logdet_Ve, logdet_Q;

  DMatrix D_l; // = gsl_vector_alloc(d_size);
  DMatrix UltVeh; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehi; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix Qi; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix Qi_temp; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix WHiy; // = gsl_vector_alloc(dc_size);
  DMatrix QiWHiy; // = gsl_vector_alloc(dc_size);
  DMatrix beta; // = gsl_vector_alloc(dc_size);
  DMatrix Vbeta; // = gsl_matrix_alloc(dc_size, dc_size);

  WHiy = zeros_dmatrix(WHiy.shape[0], WHiy.shape[1]);

  // Eigen decomposition and calculate log|Ve|.
  // double logdet_Ve = EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);
  EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);

  // Calculate Qi and log|Q|.
  // double logdet_Q = CalcQi(eval, D_l, W, Qi);
  CalcQi(eval, D_l, W, Qi);

  // Calculate UltVehiY.
  UltVehiY = matrix_mult(UltVehi, Y);

  // Calculate WHiy.
  for (size_t i = 0; i < d_size; i++) {
    dl = D_l.accessor(i);

    for (size_t j = 0; j < c_size; j++) {
      d = 0.0;
      for (size_t k = 0; k < n_size; k++) {
        delta = eval.elements[k];
        dw = W.accessor(j, k);
        dy = UltVehiY.accessor(i, k);

        d += dy * dw / (delta * dl + 1.0);
      }
      WHiy.elements[j * d_size + i] = d;
    }
  }

  QiWHiy = matrix_mult(Qi, WHiy);

  // Need to multiply I_c\otimes UltVehi on both sides or one side.
  for (size_t i = 0; i < c_size; i++) {
    //gsl_vector_view
    DMatrix QiWHiy_sub ;//= gsl_vector_subvector(QiWHiy, i * d_size, d_size);
    //gsl_vector_view
    DMatrix beta_sub;// = gsl_vector_subvector(beta, i * d_size, d_size);
    beta_sub = matrix_mult(UltVeh, QiWHiy_sub);

    for (size_t j = 0; j < c_size; j++) {
      //gsl_matrix_view
      DMatrix Qi_sub = gsl_matrix_submatrix(Qi, i * d_size, j * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix Qitemp_sub = gsl_matrix_submatrix(Qi_temp, i * d_size, j * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix Vbeta_sub = gsl_matrix_submatrix(Vbeta, i * d_size, j * d_size, d_size, d_size);

      if (j < i) {
        //gsl_matrix_view
        DMatrix Vbeta_sym = gsl_matrix_submatrix(Vbeta, j * d_size, i * d_size, d_size, d_size);
        gsl_matrix_transpose_memcpy(Vbeta_sub, Vbeta_sym);
      } else {
        Qitemp_sub = matrix_mult(Qi_sub, UltVeh);
        Vbeta_sub = matrix_mult(UltVeh, Qitemp_sub);
      }
    }
  }

  // Copy beta to B, and Vbeta to se_B.
  for (size_t j = 0; j < B.shape[1]; j++) {
    for (size_t i = 0; i < B.shape[0]; i++) {
      B.set(i, j) = beta.accessor(j * d_size + i);
      se_B.set(i, j) = sqrt(Vbeta.accessor(j * d_size + i, j * d_size + i));
    }
  }

  return;
}

// Calculate first-order and second-order derivatives.
void CalcDev(){
             //const char func_name, const gsl_vector *eval, const gsl_matrix *Qi,
             //const gsl_matrix *Hi, const gsl_matrix *xHi, const gsl_matrix *Hiy,
             //const gsl_vector *QixHiy, gsl_vector *gradient,
             //gsl_matrix *Hessian_inv, double &crt_a, double &crt_b,
             //double &crt_c) {
  if (func_name != 'R' && func_name != 'L' && func_name != 'r' && func_name != 'l') {
    writeln("func_name only takes 'R' or 'L': 'R' for log-restricted likelihood, 'L' for log-likelihood.");
    return;
  }

  size_t dc_size = Qi.shape[0], d_size = Hi.shape[0];
  size_t c_size = dc_size / d_size;
  size_t v_size = d_size * (d_size + 1) / 2;
  size_t v1, v2;
  double dev1_g, dev1_e, dev2_gg, dev2_ee, dev2_ge;

  DMatrix Hessian; // = gsl_matrix_alloc(v_size * 2, v_size * 2);

  DMatrix xHiDHiy_all_g; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix xHiDHiy_all_e; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix xHiDHix_all_g; // = gsl_matrix_alloc(dc_size, v_size * dc_size);
  DMatrix xHiDHix_all_e; // = gsl_matrix_alloc(dc_size, v_size * dc_size);
  DMatrix xHiDHixQixHiy_all_g; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix xHiDHixQixHiy_all_e; // = gsl_matrix_alloc(dc_size, v_size);

  DMatrix QixHiDHiy_all_g; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix QixHiDHiy_all_e; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix QixHiDHix_all_g; // = gsl_matrix_alloc(dc_size, v_size * dc_size);
  DMatrix QixHiDHix_all_e; // = gsl_matrix_alloc(dc_size, v_size * dc_size);
  DMatrix QixHiDHixQixHiy_all_g; // = gsl_matrix_alloc(dc_size, v_size);
  DMatrix QixHiDHixQixHiy_all_e; // = gsl_matrix_alloc(dc_size, v_size);

  DMatrix xHiDHiDHiy_all_gg; // = gsl_matrix_alloc(dc_size, v_size * v_size);
  DMatrix xHiDHiDHiy_all_ee; // = gsl_matrix_alloc(dc_size, v_size * v_size);
  DMatrix xHiDHiDHiy_all_ge; // = gsl_matrix_alloc(dc_size, v_size * v_size);
  DMatrix xHiDHiDHix_all_gg; // = gsl_matrix_alloc(dc_size, v_size * v_size * dc_size);
  DMatrix xHiDHiDHix_all_ee; // = gsl_matrix_alloc(dc_size, v_size * v_size * dc_size);
  DMatrix xHiDHiDHix_all_ge; // = gsl_matrix_alloc(dc_size, v_size * v_size * dc_size);

  // Calculate xHiDHiy_all, xHiDHix_all and xHiDHixQixHiy_all.
  Calc_xHiDHiy_all(eval, xHi, Hiy, xHiDHiy_all_g, xHiDHiy_all_e);
  Calc_xHiDHix_all(eval, xHi, xHiDHix_all_g, xHiDHix_all_e);
  Calc_xHiDHixQixHiy_all(xHiDHix_all_g, xHiDHix_all_e, QixHiy,
                         xHiDHixQixHiy_all_g, xHiDHixQixHiy_all_e);

  Calc_xHiDHiDHiy_all(v_size, eval, Hi, xHi, Hiy, xHiDHiDHiy_all_gg, xHiDHiDHiy_all_ee, xHiDHiDHiy_all_ge);
  Calc_xHiDHiDHix_all(v_size, eval, Hi, xHi, xHiDHiDHix_all_gg, xHiDHiDHix_all_ee, xHiDHiDHix_all_ge);

  // Calculate QixHiDHiy_all, QixHiDHix_all and QixHiDHixQixHiy_all.
  Calc_QiVec_all(Qi, xHiDHiy_all_g, xHiDHiy_all_e, QixHiDHiy_all_g, QixHiDHiy_all_e);
  Calc_QiVec_all(Qi, xHiDHixQixHiy_all_g, xHiDHixQixHiy_all_e, QixHiDHixQixHiy_all_g, QixHiDHixQixHiy_all_e);
  Calc_QiMat_all(Qi, xHiDHix_all_g, xHiDHix_all_e, QixHiDHix_all_g, QixHiDHix_all_e);

  double tHiD_g, tHiD_e, tPD_g, tPD_e, tHiDHiD_gg, tHiDHiD_ee;
  double tHiDHiD_ge, tPDPD_gg, tPDPD_ee, tPDPD_ge;
  double yPDPy_g, yPDPy_e, yPDPDPy_gg, yPDPDPy_ee, yPDPDPy_ge;

  // Calculate gradient and Hessian for Vg.
  for (size_t i1 = 0; i1 < d_size; i1++) {
    for (size_t j1 = 0; j1 < d_size; j1++) {
      if (j1 < i1) {
        continue;
      }
      v1 = GetIndex(i1, j1, d_size);

      Calc_yPDPy(eval, Hiy, QixHiy, xHiDHiy_all_g, xHiDHiy_all_e, xHiDHixQixHiy_all_g, xHiDHixQixHiy_all_e, i1, j1, yPDPy_g, yPDPy_e);

      if (func_name == 'R' || func_name == 'r') {
        Calc_tracePD(eval, Qi, Hi, xHiDHix_all_g, xHiDHix_all_e, i1, j1, tPD_g, tPD_e);

        dev1_g = -0.5 * tPD_g + 0.5 * yPDPy_g;
        dev1_e = -0.5 * tPD_e + 0.5 * yPDPy_e;
      } else {
        Calc_traceHiD(eval, Hi, i1, j1, tHiD_g, tHiD_e);

        dev1_g = -0.5 * tHiD_g + 0.5 * yPDPy_g;
        dev1_e = -0.5 * tHiD_e + 0.5 * yPDPy_e;
      }

      gsl_vector_set(gradient, v1, dev1_g);
      gsl_vector_set(gradient, v1 + v_size, dev1_e);

      for (size_t i2 = 0; i2 < d_size; i2++) {
        for (size_t j2 = 0; j2 < d_size; j2++) {
          if (j2 < i2) {
            continue;
          }
          v2 = GetIndex(i2, j2, d_size);

          if (v2 < v1) {
            continue;
          }

          Calc_yPDPDPy(eval, Hi, xHi, Hiy, QixHiy, xHiDHiy_all_g, xHiDHiy_all_e,
                       QixHiDHiy_all_g, QixHiDHiy_all_e, xHiDHixQixHiy_all_g,
                       xHiDHixQixHiy_all_e, QixHiDHixQixHiy_all_g,
                       QixHiDHixQixHiy_all_e, xHiDHiDHiy_all_gg,
                       xHiDHiDHiy_all_ee, xHiDHiDHiy_all_ge, xHiDHiDHix_all_gg,
                       xHiDHiDHix_all_ee, xHiDHiDHix_all_ge, i1, j1, i2, j2,
                       yPDPDPy_gg, yPDPDPy_ee, yPDPDPy_ge);

          // AI for REML.
          if (func_name == 'R' || func_name == 'r') {
            Calc_tracePDPD(eval, Qi, Hi, xHi, QixHiDHix_all_g, QixHiDHix_all_e,
                           xHiDHiDHix_all_gg, xHiDHiDHix_all_ee,
                           xHiDHiDHix_all_ge, i1, j1, i2, j2, tPDPD_gg,
                           tPDPD_ee, tPDPD_ge);

            dev2_gg = 0.5 * tPDPD_gg - yPDPDPy_gg;
            dev2_ee = 0.5 * tPDPD_ee - yPDPDPy_ee;
            dev2_ge = 0.5 * tPDPD_ge - yPDPDPy_ge;
          } else {
            Calc_traceHiDHiD(eval, Hi, i1, j1, i2, j2, tHiDHiD_gg, tHiDHiD_ee,
                             tHiDHiD_ge);

            dev2_gg = 0.5 * tHiDHiD_gg - yPDPDPy_gg;
            dev2_ee = 0.5 * tHiDHiD_ee - yPDPDPy_ee;
            dev2_ge = 0.5 * tHiDHiD_ge - yPDPDPy_ge;
          }

          // Set up Hessian.
          Hessian.set(v1, v2) = dev2_gg;
          Hessian.set(v1 + v_size, v2 + v_size) = dev2_ee;
          Hessian.set(v1, v2 + v_size) = dev2_ge;
          Hessian.set(v2 + v_size, v1) = dev2_ge;

          if (v1 != v2) {
            Hessian.set(v2, v1) = dev2_gg;
            Hessian.set(v2 + v_size, v1 + v_size) = dev2_ee;
            Hessian.set(v2, v1 + v_size) = dev2_ge;
            Hessian.set(v1 + v_size, v2) = dev2_ge;
          }
        }
      }
    }
  }

  // Invert Hessian.
  int sig;
  gsl_permutation *pmt = gsl_permutation_alloc(v_size * 2);

  LUDecomp(Hessian, pmt, &sig);
  LUInvert(Hessian, pmt, Hessian_inv);

  gsl_permutation_free(pmt);

  // Calculate Edgeworth correction factors after inverting
  // Hessian.
  if (c_size > 1) {
    CalcCRT(Hessian_inv, Qi, QixHiDHix_all_g, QixHiDHix_all_e,
            xHiDHiDHix_all_gg, xHiDHiDHix_all_ee, xHiDHiDHix_all_ge, d_size,
            crt_a, crt_b, crt_c);
  } else {
    crt_a = 0.0;
    crt_b = 0.0;
    crt_c = 0.0;
  }

  return;
}

// Calculate (xHiDHiy) for every pair (i,j).
void Calc_xHiDHiy_all(){
                      //const gsl_vector *eval, const gsl_matrix *xHi,
                      //const gsl_matrix *Hiy, gsl_matrix *xHiDHiy_all_g,
                      //gsl_matrix *xHiDHiy_all_e) {
  xHiDHiy_all_g = zeros_dmatrix(xHiDHiy_all_g.shape[0], xHiDHiy_all_g.shape[1]);
  xHiDHiy_all_e = zeros_dmatrix(xHiDHiy_all_e.shape[0], xHiDHiy_all_e.shape[1]);

  size_t d_size = Hiy.shape[0];
  size_t v;

  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j < d_size; j++) {
      if (j < i) {
        continue;
      }
      v = GetIndex(i, j, d_size);

      //gsl_vector_view
      DMatrix xHiDHiy_g = get_col(xHiDHiy_all_g, v);
      //gsl_vector_view
      DMatrix xHiDHiy_e = get_col(xHiDHiy_all_e, v);

      Calc_xHiDHiy(eval, xHi, Hiy, i, j, xHiDHiy_g, xHiDHiy_e);
    }
  }
  return;
}

// Calculate (xHiDHix) for every pair (i,j).
void Calc_xHiDHix_all(){
                      //const gsl_vector *eval, const gsl_matrix *xHi,
                      //gsl_matrix *xHiDHix_all_g, gsl_matrix *xHiDHix_all_e) {
  xHiDHix_all_g = zeros_dmatrix(xHiDHix_all_g.shape[0]. xHiDHix_all_g.shape[1]);
  xHiDHix_all_e = zeros_dmatrix(xHiDHix_all_e.shape[0]. xHiDHix_all_e.shape[1]);

  size_t d_size = xHi.shape[1] / eval.size, dc_size = xHi.shape[0];
  size_t v;

  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j < d_size; j++) {
      if (j < i) {
        continue;
      }
      v = GetIndex(i, j, d_size);

      //gsl_matrix_view
      DMatrix xHiDHix_g = get_sub_dmatrix(xHiDHix_all_g, 0, v * dc_size, dc_size, dc_size);
      //gsl_matrix_view
      DMatrix xHiDHix_e = get_sub_dmatrix(xHiDHix_all_e, 0, v * dc_size, dc_size, dc_size);

      Calc_xHiDHix(eval, xHi, i, j, xHiDHix_g, xHiDHix_e);
    }
  }
  return;
}

// Calculate (xHiDHiy) for every pair (i,j).
void Calc_xHiDHiDHiy_all(){
                         //const size_t v_size, const gsl_vector *eval,
                         //const gsl_matrix *Hi, const gsl_matrix *xHi,
                         //const gsl_matrix *Hiy, gsl_matrix *xHiDHiDHiy_all_gg,
                         //gsl_matrix *xHiDHiDHiy_all_ee,
                         //gsl_matrix *xHiDHiDHiy_all_ge) {
  xHiDHiDHiy_all_gg = zeros_dmatrix(xHiDHiDHiy_all_gg.shape[0], xHiDHiDHiy_all_gg.shape[1]);
  xHiDHiDHiy_all_ee = zeros_dmatrix(xHiDHiDHiy_all_ee.shape[0], xHiDHiDHiy_all_ee.shape[1]);
  xHiDHiDHiy_all_ge = zeros_dmatrix(xHiDHiDHiy_all_ge.shape[0], xHiDHiDHiy_all_ge.shape[1]);

  size_t d_size = Hiy.shape[0];
  size_t v1, v2;

  for (size_t i1 = 0; i1 < d_size; i1++) {
    for (size_t j1 = 0; j1 < d_size; j1++) {
      if (j1 < i1) {
        continue;
      }
      v1 = GetIndex(i1, j1, d_size);

      for (size_t i2 = 0; i2 < d_size; i2++) {
        for (size_t j2 = 0; j2 < d_size; j2++) {
          if (j2 < i2) {
            continue;
          }
          v2 = GetIndex(i2, j2, d_size);

          //gsl_vector_view
          DMatrix xHiDHiDHiy_gg = get_col(xHiDHiDHiy_all_gg, v1 * v_size + v2);
          //gsl_vector_view
          DMatrix xHiDHiDHiy_ee = get_col(xHiDHiDHiy_all_ee, v1 * v_size + v2);
          //gsl_vector_view
          DMatrix xHiDHiDHiy_ge = get_col(xHiDHiDHiy_all_ge, v1 * v_size + v2);

          Calc_xHiDHiDHiy(eval, Hi, xHi, Hiy, i1, j1, i2, j2, xHiDHiDHiy_gg, xHiDHiDHiy_ee, xHiDHiDHiy_ge);
        }
      }
    }
  }
  return;
}

// Calculate (xHiDHix) for every pair (i,j).
void Calc_xHiDHiDHix_all(){
                         //(const size_t v_size, const gsl_vector *eval,
                         //const gsl_matrix *Hi, const gsl_matrix *xHi,
                         //gsl_matrix *xHiDHiDHix_all_gg,
                         //gsl_matrix *xHiDHiDHix_all_ee,
                         //gsl_matrix *xHiDHiDHix_all_ge) {
  xHiDHiDHix_all_gg = zeros_dmatrix(xHiDHiDHix_all_gg.shape[0], xHiDHiDHix_all_gg.shape[1]);
  xHiDHiDHix_all_ee = zeros_dmatrix(xHiDHiDHix_all_ee.shape[0], xHiDHiDHix_all_ee.shape[1]);
  xHiDHiDHix_all_ge = zeros_dmatrix(xHiDHiDHix_all_ge.shape[0], xHiDHiDHix_all_ge.shape[1]);

  size_t d_size = xHi.shape[1] / eval.size, dc_size = xHi.shape[0];
  size_t v1, v2;

  for (size_t i1 = 0; i1 < d_size; i1++) {
    for (size_t j1 = 0; j1 < d_size; j1++) {
      if (j1 < i1) {
        continue;
      }
      v1 = GetIndex(i1, j1, d_size);

      for (size_t i2 = 0; i2 < d_size; i2++) {
        for (size_t j2 = 0; j2 < d_size; j2++) {
          if (j2 < i2) {
            continue;
          }
          v2 = GetIndex(i2, j2, d_size);

          if (v2 < v1) {
            continue;
          }

          //gsl_matrix_view
          DMatrix xHiDHiDHix_gg1 = get_sub_dmatrix( xHiDHiDHix_all_gg, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
          //gsl_matrix_view
          DMatrix xHiDHiDHix_ee1 = get_sub_dmatrix( xHiDHiDHix_all_ee, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
          //gsl_matrix_view
          DMatrix xHiDHiDHix_ge1 = get_sub_dmatrix( xHiDHiDHix_all_ge, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);

          Calc_xHiDHiDHix(eval, Hi, xHi, i1, j1, i2, j2, xHiDHiDHix_gg1, xHiDHiDHix_ee1, xHiDHiDHix_ge1);

          if (v2 != v1) {
            //gsl_matrix_view
            DMatrix xHiDHiDHix_gg2 = get_sub_dmatrix( xHiDHiDHix_all_gg, 0, (v2 * v_size + v1) * dc_size, dc_size, dc_size);
            //gsl_matrix_view
            DMatrix xHiDHiDHix_ee2 = get_sub_dmatrix( xHiDHiDHix_all_ee, 0, (v2 * v_size + v1) * dc_size, dc_size, dc_size);
            //gsl_matrix_view
            DMatrix xHiDHiDHix_ge2 = get_sub_dmatrix( xHiDHiDHix_all_ge, 0, (v2 * v_size + v1) * dc_size, dc_size, dc_size);

            //gsl_matrix_memcpy(xHiDHiDHix_gg2, xHiDHiDHix_gg1);
            //gsl_matrix_memcpy(xHiDHiDHix_ee2, xHiDHiDHix_ee1);
            //gsl_matrix_memcpy(xHiDHiDHix_ge2, xHiDHiDHix_ge1);
          }
        }
      }
    }
  }

  return;
}

// Calculate (xHiDHix)Qi(xHiy) for every pair (i,j).
void Calc_xHiDHixQixHiy_all(){
                            //const gsl_matrix *xHiDHix_all_g,
                            //const gsl_matrix *xHiDHix_all_e,
                            //const gsl_vector *QixHiy,
                            //gsl_matrix *xHiDHixQixHiy_all_g,
                            //gsl_matrix *xHiDHixQixHiy_all_e) {
  size_t dc_size = xHiDHix_all_g.shape[0];
  size_t v_size = xHiDHix_all_g.shape[1] / dc_size;

  for (size_t i = 0; i < v_size; i++) {
    //gsl_matrix_const_view
    DMatrix xHiDHix_g = get_sub_dmatrix( xHiDHix_all_g, 0, i * dc_size, dc_size, dc_size);
    //gsl_matrix_const_view
    DMatrix xHiDHix_e = get_sub_dmatrix( xHiDHix_all_e, 0, i * dc_size, dc_size, dc_size);

    DMatrix xHiDHixQixHiy_g = get_col(xHiDHixQixHiy_all_g, i);
    DMatrix xHiDHixQixHiy_e = get_col(xHiDHixQixHiy_all_e, i);

    xHiDHixQixHiy_g = matrix_mult(xHiDHix_g, QixHiy);
    xHiDHixQixHiy_e = matrix_mult(xHiDHix_e, QixHiy);
  }

  return;
}

// Calculate Qi(xHiDHiy) and Qi(xHiDHix)Qi(xHiy) for each pair of i,j (i<=j).
void Calc_QiVec_all(){
                    //const gsl_matrix *Qi, const gsl_matrix *vec_all_g,
                    //const gsl_matrix *vec_all_e, gsl_matrix *Qivec_all_g,
                    //gsl_matrix *Qivec_all_e) {
  for (size_t i = 0; i < vec_all_g.shape[1]; i++) {
    //gsl_vector_const_view
    DMatrix vec_g = get_col(vec_all_g, i);
    //gsl_vector_const_view
    DMatrix vec_e = get_col(vec_all_e, i);

    //gsl_vector_view
    DMatrix Qivec_g = get_col(Qivec_all_g, i);
    //gsl_vector_view
    DMatrix Qivec_e = get_col(Qivec_all_e, i);

    Qivec_g = matrix_mult(Qi, vec_g);
    Qivec_e = matrix_mult(Qi, vec_e);
  }

  return;
}

// Calculate Qi(xHiDHix) for each pair of i,j (i<=j).
void Calc_QiMat_all(){
                    //const gsl_matrix *Qi, const gsl_matrix *mat_all_g,
                    //const gsl_matrix *mat_all_e, gsl_matrix *Qimat_all_g,
                    //gsl_matrix *Qimat_all_e) {
  size_t dc_size = Qi.shape[0];
  size_t v_size = mat_all_g.shape[1] / mat_all_g.shape[0];

  for (size_t i = 0; i < v_size; i++) {
    //gsl_matrix_const_view
    DMatrix mat_g = get_sub_dmatrix(mat_all_g, 0, i * dc_size, dc_size, dc_size);
    //gsl_matrix_const_view
    DMatrix mat_e = get_sub_dmatrix(mat_all_e, 0, i * dc_size, dc_size, dc_size);

    //gsl_matrix_view
    DMatrix Qimat_g = get_sub_dmatrix(Qimat_all_g, 0, i * dc_size, dc_size, dc_size);
    //gsl_matrix_view
    DMatrix Qimat_e = get_sub_dmatrix(Qimat_all_e, 0, i * dc_size, dc_size, dc_size);

    Qimat_g = matrix_mult(Qi, mat_g);
    Qimat_e = matrix_mult(Qi, mat_e);
  }

  return;
}

// Calculate yPDPy
// yPDPy = y(Hi-HixQixHi)D(Hi-HixQixHi)y
//       = ytHiDHiy - (yHix)Qi(xHiDHiy) - (yHiDHix)Qi(xHiy)
//         + (yHix)Qi(xHiDHix)Qi(xtHiy)
void Calc_yPDPy(){
                //const gsl_vector *eval, const gsl_matrix *Hiy,
                //const gsl_vector *QixHiy, const gsl_matrix *xHiDHiy_all_g,
                //const gsl_matrix *xHiDHiy_all_e,
                //const gsl_matrix *xHiDHixQixHiy_all_g,
                //const gsl_matrix *xHiDHixQixHiy_all_e, const size_t i,
                //const size_t j, double &yPDPy_g, double &yPDPy_e) {
  size_t d_size = Hiy.shape[0];
  size_t v = GetIndex(i, j, d_size);

  double d;

  // First part: ytHiDHiy.
  Calc_yHiDHiy(eval, Hiy, i, j, yPDPy_g, yPDPy_e);

  // Second and third parts: -(yHix)Qi(xHiDHiy)-(yHiDHix)Qi(xHiy)
  //gsl_vector_const_view
  DMatrix xHiDHiy_g = get_col(xHiDHiy_all_g, v);
  //gsl_vector_const_view
  DMatrix xHiDHiy_e = get_col(xHiDHiy_all_e, v);

  d = vector_ddot(QixHiy, xHiDHiy_g);
  yPDPy_g -= d * 2.0;
  d = vector_ddot(QixHiy, xHiDHiy_e);
  yPDPy_e -= d * 2.0;

  // Fourth part: +(yHix)Qi(xHiDHix)Qi(xHiy).
  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_g = get_col(xHiDHixQixHiy_all_g, v);
  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_e = get_col(xHiDHixQixHiy_all_e, v);

  d = vector_ddot(QixHiy, xHiDHixQixHiy_g);
  yPDPy_g += d;
  d = vector_ddot(QixHiy, xHiDHixQixHiy_e);
  yPDPy_e += d;

  return;
}

void Calc_yPDPDPy(){
    //const gsl_vector *eval, const gsl_matrix *Hi, const gsl_matrix *xHi,
    //const gsl_matrix *Hiy, const gsl_vector *QixHiy,
    //const gsl_matrix *xHiDHiy_all_g, const gsl_matrix *xHiDHiy_all_e,
    //const gsl_matrix *QixHiDHiy_all_g, const gsl_matrix *QixHiDHiy_all_e,
    //const gsl_matrix *xHiDHixQixHiy_all_g,
    //const gsl_matrix *xHiDHixQixHiy_all_e,
    //const gsl_matrix *QixHiDHixQixHiy_all_g,
    //const gsl_matrix *QixHiDHixQixHiy_all_e,
    //const gsl_matrix *xHiDHiDHiy_all_gg, const gsl_matrix *xHiDHiDHiy_all_ee,
    //const gsl_matrix *xHiDHiDHiy_all_ge, const gsl_matrix *xHiDHiDHix_all_gg,
    //const gsl_matrix *xHiDHiDHix_all_ee, const gsl_matrix *xHiDHiDHix_all_ge,
    //const size_t i1, const size_t j1, const size_t i2, const size_t j2,
    //double &yPDPDPy_gg, double &yPDPDPy_ee, double &yPDPDPy_ge) {
  size_t d_size = Hi.shape[0], dc_size = xHi.shape[0];
  size_t v1 = GetIndex(i1, j1, d_size), v2 = GetIndex(i2, j2, d_size);
  size_t v_size = d_size * (d_size + 1) / 2;

  double d;

  gsl_vector *xHiDHiDHixQixHiy = gsl_vector_alloc(dc_size);

  // First part: yHiDHiDHiy.
  Calc_yHiDHiDHiy(eval, Hi, Hiy, i1, j1, i2, j2, yPDPDPy_gg, yPDPDPy_ee,
                  yPDPDPy_ge);

  // Second and third parts:
  // -(yHix)Qi(xHiDHiDHiy) - (yHiDHiDHix)Qi(xHiy).
  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_gg1 = get_col(xHiDHiDHiy_all_gg, v1 * v_size + v2);
  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_ee1 = get_col(xHiDHiDHiy_all_ee, v1 * v_size + v2);
  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_ge1 = get_col(xHiDHiDHiy_all_ge, v1 * v_size + v2);

  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_gg2 = get_col(xHiDHiDHiy_all_gg, v2 * v_size + v1);
  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_ee2 = get_col(xHiDHiDHiy_all_ee, v2 * v_size + v1);
  //gsl_vector_const_view
  DMatrix xHiDHiDHiy_ge2 = get_col(xHiDHiDHiy_all_ge, v2 * v_size + v1);

  d = vector_ddot(QixHiy, xHiDHiDHiy_gg1);
  yPDPDPy_gg -= d;
  d = vector_ddot(QixHiy, xHiDHiDHiy_ee1);
  yPDPDPy_ee -= d;
  d = vector_ddot(QixHiy, xHiDHiDHiy_ge1);
  yPDPDPy_ge -= d;

  d = vector_ddot(QixHiy, xHiDHiDHiy_gg2);
  yPDPDPy_gg -= d;
  d = vector_ddot(QixHiy, xHiDHiDHiy_ee2);
  yPDPDPy_ee -= d;
  d = vector_ddot(QixHiy, xHiDHiDHiy_ge2);
  yPDPDPy_ge -= d;

  // Fourth part: - (yHiDHix)Qi(xHiDHiy).
  //gsl_vector_const_view
  DMatrix xHiDHiy_g1 = get_col(xHiDHiy_all_g, v1);
  //gsl_vector_const_view
  DMatrix xHiDHiy_e1 = get_col(xHiDHiy_all_e, v1);
  //gsl_vector_const_view
  DMatrix QixHiDHiy_g2 = get_col(QixHiDHiy_all_g, v2);
  //gsl_vector_const_view
  DMatrix QixHiDHiy_e2 = get_col(QixHiDHiy_all_e, v2);

  d = vector_ddot(xHiDHiy_g1, QixHiDHiy_g2);
  yPDPDPy_gg -= d;
  d = vector_ddot(xHiDHiy_e1, QixHiDHiy_e2);
  yPDPDPy_ee -= d;
  d = vector_ddot(xHiDHiy_g1, QixHiDHiy_e2);
  yPDPDPy_ge -= d;

  // Fifth and sixth parts:
  //   + (yHix)Qi(xHiDHix)Qi(xHiDHiy) +
  //   (yHiDHix)Qi(xHiDHix)Qi(xHiy)
  //gsl_vector_const_view
  DMatrix QixHiDHiy_g1 = get_col(QixHiDHiy_all_g, v1);
  //gsl_vector_const_view
  DMatrix QixHiDHiy_e1 = get_col(QixHiDHiy_all_e, v1);

  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_g1 = get_col(xHiDHixQixHiy_all_g, v1);
  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_e1 = get_col(xHiDHixQixHiy_all_e, v1);
  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_g2 = get_col(xHiDHixQixHiy_all_g, v2);
  //gsl_vector_const_view
  DMatrix xHiDHixQixHiy_e2 = get_col(xHiDHixQixHiy_all_e, v2);

  d = vector_ddot(xHiDHixQixHiy_g1, QixHiDHiy_g2);
  yPDPDPy_gg += d;
  d = vector_ddot(xHiDHixQixHiy_g2, QixHiDHiy_g1);
  yPDPDPy_gg += d;

  d = vector_ddot(xHiDHixQixHiy_e1, QixHiDHiy_e2);
  yPDPDPy_ee += d;
  d = vector_ddot(xHiDHixQixHiy_e2, QixHiDHiy_e1);
  yPDPDPy_ee += d;

  d = vector_ddot(xHiDHixQixHiy_g1, QixHiDHiy_e2);
  yPDPDPy_ge += d;
  d = vector_ddot(xHiDHixQixHiy_e2, QixHiDHiy_g1);
  yPDPDPy_ge += d;

  // Seventh part: + (yHix)Qi(xHiDHiDHix)Qi(xHiy)
  //gsl_matrix_const_view
  DMatrix xHiDHiDHix_gg = get_sub_dmatrix(xHiDHiDHix_all_gg, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
  //gsl_matrix_const_view
  DMatrix xHiDHiDHix_ee = get_sub_dmatrix(xHiDHiDHix_all_ee, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
  //gsl_matrix_const_view
  DMatrix xHiDHiDHix_ge = get_sub_dmatrix(xHiDHiDHix_all_ge, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);

  xHiDHiDHixQixHiy = matrix_mult(xHiDHiDHix_gg, QixHiy);
  d = vector_ddot(xHiDHiDHixQixHiy, QixHiy, &d);
  yPDPDPy_gg += d;
  xHiDHiDHixQixHiy = matrix_mult(xHiDHiDHix_ee, QixHiy);
  d = vector_ddot(xHiDHiDHixQixHiy, QixHiy, &d);
  yPDPDPy_ee += d;
  xHiDHiDHixQixHiy = matrix_mult(xHiDHiDHix_ge, QixHiy);
  d = vector_ddot(xHiDHiDHixQixHiy, QixHiy, &d);
  yPDPDPy_ge += d;

  // Eighth part: - (yHix)Qi(xHiDHix)Qi(xHiDHix)Qi(xHiy).
  //gsl_vector_const_view
  DMatrix QixHiDHixQixHiy_g1 = get_col(QixHiDHixQixHiy_all_g, v1);
  //gsl_vector_const_view
  DMatrix QixHiDHixQixHiy_e1 = get_col(QixHiDHixQixHiy_all_e, v1);

  d = (QixHiDHixQixHiy_g1, xHiDHixQixHiy_g2);
  yPDPDPy_gg -= d;
  d = (QixHiDHixQixHiy_e1, xHiDHixQixHiy_e2);
  yPDPDPy_ee -= d;
  d = (QixHiDHixQixHiy_g1, xHiDHixQixHiy_e2);
  yPDPDPy_ge -= d;

  return;
}

// Calculate Edgeworth correctation factors for small samples notation
// and method follows Thomas J. Rothenberg, Econometirca 1984; 52 (4)
// M=xHiDHix
void CalcCRT(){
             //const gsl_matrix *Hessian_inv, const gsl_matrix *Qi,
             //const gsl_matrix *QixHiDHix_all_g,
             //const gsl_matrix *QixHiDHix_all_e,
             //const gsl_matrix *xHiDHiDHix_all_gg,
             //const gsl_matrix *xHiDHiDHix_all_ee,
             //const gsl_matrix *xHiDHiDHix_all_ge, const size_t d_size,
             //double &crt_a, double &crt_b, double &crt_c) {
  crt_a = 0.0;
  crt_b = 0.0;
  crt_c = 0.0;

  size_t dc_size = Qi.shape[0], v_size = Hessian_inv.shape[0] / 2;
  size_t c_size = dc_size / d_size;
  double h_gg, h_ge, h_ee, d, B = 0.0, C = 0.0, D = 0.0;
  double trCg1, trCe1, trCg2, trCe2, trB_gg, trB_ge, trB_ee;
  double trCC_gg, trCC_ge, trCC_ee, trD_gg = 0.0, trD_ge = 0.0, trD_ee = 0.0;

  DMatrix QiMQi_g1; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMQi_e1; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMQi_g2; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMQi_e2; // = gsl_matrix_alloc(dc_size, dc_size);

  DMatrix QiMQisQisi_g1; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix QiMQisQisi_e1; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix QiMQisQisi_g2; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix QiMQisQisi_e2; // = gsl_matrix_alloc(d_size, d_size);

  DMatrix QiMQiMQi_gg; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMQiMQi_ge; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMQiMQi_ee; // = gsl_matrix_alloc(dc_size, dc_size);

  DMatrix QiMMQi_gg; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMMQi_ge; // = gsl_matrix_alloc(dc_size, dc_size);
  DMatrix QiMMQi_ee; // = gsl_matrix_alloc(dc_size, dc_size);

  DMatrix Qi_si; // = gsl_matrix_alloc(d_size, d_size);

  DMatrix M_dd; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix M_dcdc; // = gsl_matrix_alloc(dc_size, dc_size);

  // Invert Qi_sub to Qi_si.
  DMatrix Qi_sub; // = gsl_matrix_alloc(d_size, d_size);

  //gsl_matrix_const_view
  DMatrix Qi_s = get_sub_dmatrix( Qi, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);

  int sig;
  gsl_permutation *pmt = gsl_permutation_alloc(d_size);

  //gsl_matrix_memcpy(Qi_sub, &Qi_s);
  LUDecomp(Qi_sub, pmt, &sig);
  LUInvert(Qi_sub, pmt, Qi_si);

  gsl_permutation_free(pmt);
  gsl_matrix_free(Qi_sub);

  // Calculate correction factors.
  for (size_t v1 = 0; v1 < v_size; v1++) {

    // Calculate Qi(xHiDHix)Qi, and subpart of it.
    //gsl_matrix_const_view
    DMatrix QiM_g1 = get_sub_dmatrix(QixHiDHix_all_g, 0, v1 * dc_size, dc_size, dc_size);
    //gsl_matrix_const_view
    DMatrix QiM_e1 = get_sub_dmatrix(QixHiDHix_all_e, 0, v1 * dc_size, dc_size, dc_size);

    QiMQi_g1 = matrix_mult(QiM_g, Qi);
    QiMQi_e1 = matrix_mult(QiM_e, Qi);

    //gsl_matrix_view
    DMatrix QiMQi_g1_s = get_sub_dmatrix(QiMQi_g1, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
    //gsl_matrix_view
    DMatrix QiMQi_e1_s = get_sub_dmatrix(QiMQi_e1, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);

    // Calculate trCg1 and trCe1.
    QiMQisQisi_g1 = matrix_mult(QiMQi_g1_s, Qi_si);
    trCg1 = 0.0;
    for (size_t k = 0; k < d_size; k++) {
      trCg1 -= QiMQisQisi_g1.accessor(k, k);
    }

    QiMQisQisi_e1 = matrix_mult(QiMQi_e1_s, Qi_si);
    trCe1 = 0.0;
    for (size_t k = 0; k < d_size; k++) {
      trCe1 -= QiMQisQisi_e1.accessor(k, k);
    }

    for (size_t v2 = 0; v2 < v_size; v2++) {
      if (v2 < v1) {
        continue;
      }

      // Calculate Qi(xHiDHix)Qi, and subpart of it.
      //gsl_matrix_const_view
      DMatrix QiM_g2 = get_sub_dmatrix(QixHiDHix_all_g, 0, v2 * dc_size, dc_size, dc_size);
      //gsl_matrix_const_view
      DMatrix QiM_e2 = get_sub_dmatrix(QixHiDHix_all_e, 0, v2 * dc_size, dc_size, dc_size);

      QiMQi_g2 = matrix_mult(QiM_g2, Qi);
      QiMQi_e2 = matrix_mult(QiM_e2, Qi);

      //gsl_matrix_view
      DMatrix QiMQi_g2_s = get_sub_dmatrix(QiMQi_g2, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix QiMQi_e2_s = get_sub_dmatrix(QiMQi_e2, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);

      // Calculate trCg2 and trCe2.
      QiMQisQisi_g2 = matrix_mult(QiMQi_g2_s, Qi_si);
      trCg2 = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        trCg2 -= QiMQisQisi_g2.accessor(k, k);
      }

      QiMQisQisi_e2 = matrix_mult(QiMQi_e2_s, Qi_si);
      trCe2 = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        trCe2 -= QiMQisQisi_e2.accessor(k, k);
      }

      // Calculate trCC_gg, trCC_ge, trCC_ee.
      M_dd = matrix_mult(QiMQisQisi_g1, QiMQisQisi_g2);
      trCC_gg = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        trCC_gg += M_dd.accessor(k, k);
      }

      M_dd = matrix_mult(QiMQisQisi_g1, QiMQisQisi_e2);
      M_dd = matrix_mult(QiMQisQisi_e1, QiMQisQisi_g2);
      trCC_ge = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        trCC_ge += M_dd.accessor(k, k);
      }

      M_dd = matrix_mult(QiMQisQisi_e1, QiMQisQisi_e2);
      trCC_ee = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        trCC_ee += M_dd.accessor(k, k);
      }

      // Calculate Qi(xHiDHix)Qi(xHiDHix)Qi, and subpart of it.
       QiMQiMQi_gg = matrix_mult(QiM_g1, QiMQi_g2);
       QiMQiMQi_ge = matrix_mult(QiM_g1, QiMQi_e2);
       QiMQiMQi_ge = matrix_mult(QiM_e1, QiMQi_g2);
       QiMQiMQi_ee = matrix_mult(QiM_e1, QiMQi_e2);

      //gsl_matrix_view
      DMatrix QiMQiMQi_gg_s = get_sub_dmatrix(QiMQiMQi_gg, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix QiMQiMQi_ge_s = get_sub_dmatrix(QiMQiMQi_ge, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix QiMQiMQi_ee_s = get_sub_dmatrix(QiMQiMQi_ee, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);

      // and part of trB_gg, trB_ge, trB_ee.
      M_dd = matrix_mult(QiMQiMQi_gg_s, Qi_si);
      trB_gg = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        d = M_dd.accessor(k, k);
        trB_gg -= d;
      }

      M_dd = matrix_mult(QiMQiMQi_ge_s, Qi_si);
      trB_ge = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        d = M_dd.accessor(k, k);
        trB_ge -= d;
      }

      M_dd = matrix_mult(QiMQiMQi_ee_s, Qi_si);
      trB_ee = 0.0;
      for (size_t k = 0; k < d_size; k++) {
        d = M_dd.accessor(k, k);
        trB_ee -= d;
      }

      // Calculate Qi(xHiDHiDHix)Qi, and subpart of it.
      //gsl_matrix_const_view
      DMatrix MM_gg = get_sub_dmatrix(xHiDHiDHix_all_gg, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
      //gsl_matrix_const_view
      DMatrix MM_ge = get_sub_dmatrix(xHiDHiDHix_all_ge, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);
      //gsl_matrix_const_view
      DMatrix MM_ee = get_sub_dmatrix(xHiDHiDHix_all_ee, 0, (v1 * v_size + v2) * dc_size, dc_size, dc_size);

      M_dcdc    = matrix_mult(Qi,     MM_gg);
      QiMMQi_gg = matrix_mult(M_dcdc, Qi,);
      M_dcdc    = matrix_mult(Qi,     MM_ge);
      QiMMQi_ge = matrix_mult(M_dcdc, Qi,);
      M_dcdc    = matrix_mult(Qi,     MM_ee);
      QiMMQi_ee = matrix_mult(M_dcdc, Qi,);

      //gsl_matrix_view
      DMatrix QiMMQi_gg_s = get_sub_dmatrix(QiMMQi_gg, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix QiMMQi_ge_s = get_sub_dmatrix(QiMMQi_ge, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);
      //gsl_matrix_view
      DMatrix QiMMQi_ee_s = get_sub_dmatrix(QiMMQi_ee, (c_size - 1) * d_size, (c_size - 1) * d_size, d_size, d_size);

      // Calculate the other part of trB_gg, trB_ge, trB_ee.
      M_dd = matrix_mult(QiMMQi_gg_s, Qi_si);
      for (size_t k = 0; k < d_size; k++) {
        trB_gg += M_dd.accessor(k, k);
      }
      M_dd = matrix_mult(QiMMQi_ge_s, Qi_si);
      for (size_t k = 0; k < d_size; k++) {
        trB_ge += 2.0 * M_dd.accessor(k, k);
      }
      M_dd = matrix_mult(QiMMQi_ee_s, Qi_si);
      for (size_t k = 0; k < d_size; k++) {
        trB_ee += M_dd.accessor(k, k);
      }

      // Calculate trD_gg, trD_ge, trD_ee.
      trD_gg = 2.0 * trB_gg;
      trD_ge = 2.0 * trB_ge;
      trD_ee = 2.0 * trB_ee;

      // calculate B, C and D
      h_gg = -1.0 * Hessian_inv.accessor(v1, v2);
      h_ge = -1.0 * Hessian_inv.accessor(v1, v2 + v_size);
      h_ee = -1.0 * Hessian_inv.accessor(v1 + v_size, v2 + v_size);

      B += h_gg * trB_gg + h_ge * trB_ge + h_ee * trB_ee;
      C += h_gg * (trCC_gg + 0.5 * trCg1 * trCg2) +
           h_ge * (trCC_ge + 0.5 * trCg1 * trCe2 + 0.5 * trCe1 * trCg2) +
           h_ee * (trCC_ee + 0.5 * trCe1 * trCe2);
      D += h_gg * (trCC_gg + 0.5 * trD_gg) + h_ge * (trCC_ge + 0.5 * trD_ge) +
           h_ee * (trCC_ee + 0.5 * trD_ee);

      if (v1 != v2) {
        B += h_gg * trB_gg + h_ge * trB_ge + h_ee * trB_ee;
        C += h_gg * (trCC_gg + 0.5 * trCg1 * trCg2) +
             h_ge * (trCC_ge + 0.5 * trCg1 * trCe2 + 0.5 * trCe1 * trCg2) +
             h_ee * (trCC_ee + 0.5 * trCe1 * trCe2);
        D += h_gg * (trCC_gg + 0.5 * trD_gg) + h_ge * (trCC_ge + 0.5 * trD_ge) +
             h_ee * (trCC_ee + 0.5 * trD_ee);
      }
    }
  }

  // Calculate a, b, c from B C D.
  crt_a = 2.0 * D - C;
  crt_b = 2.0 * B;
  crt_c = C;

  return;
}
// Update Vg, Ve.
void UpdateVgVe(){
                //const gsl_matrix *Hessian_inv, const gsl_vector *gradient,
                //const double step_scale, gsl_matrix *V_g, gsl_matrix *V_e) {
  size_t v_size = gradient.size / 2, d_size = V_g.shape[0];
  size_t v;

  DMatrix vec_v; // = gsl_vector_alloc(v_size * 2);

  double d;

  // Vectorize Vg and Ve.
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j < d_size; j++) {
      if (j < i) {
        continue;
      }
      v = GetIndex(i, j, d_size);

      d = V_g.accessor(i, j);
      vec_v.elements[v] = d;

      d = V_e.accessor(i, j);
      vec_v.elements[v + v_size] = d;
    }
  }

  //vec_v = matrix_mult(-1.0 * step_scale, Hessian_inv, gradient); // TODO

  // Save Vg and Ve.
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j < d_size; j++) {
      if (j < i) {
        continue;
      }
      v = GetIndex(i, j, d_size);

      d = vec_v.elements[v];
      V_g.set(i, j) = d;
      V_g.set(j, i) = d;

      d = vec_v.elements[v + v_size];
      V_e.set(i, j) = d;
      V_e.set(j, i) = d;
    }
  }

  return;
}

// p-value correction
// mode=1 Wald; mode=2 LRT; mode=3 SCORE;
double PCRT(const size_t mode, const size_t d_size, const double p_value,
            const double crt_a, const double crt_b, const double crt_c) {
  double p_crt = 0.0, chisq_crt = 0.0, q = to!double(d_size);
  double chisq = gsl_cdf_chisq_Qinv(p_value, to!double(d_size));

  if (mode == 1) {
    double a = crt_c / (2.0 * q * (q + 2.0));
    double b = 1.0 + (crt_a + crt_b) / (2.0 * q);
    chisq_crt = (-1.0 * b + sqrt(b * b + 4.0 * a * chisq)) / (2.0 * a);
  } else if (mode == 2) {
    chisq_crt = chisq / (1.0 + crt_a / (2.0 * q));
  } else {
    chisq_crt = chisq;
  }

  p_crt = gsl_cdf_chisq_Q(chisq_crt, to!double(d_size));

  return p_crt;
}

void analyze_plink(){
//                  (const gsl_matrix *U, const gsl_vector *eval,
//                    const gsl_matrix *UtW, const gsl_matrix *UtY) {
  debug_msg("entering");
  string file_bed = file_bfile + ".bed";
  if (!infile) {
    writeln("error reading bed file:");
    return;
  }


  char ch;
  //bitset<8> b;
  bit[] b;

  double logl_H0 = 0.0, logl_H1 = 0.0, p_wald = 0, p_lrt = 0, p_score = 0;
  double crt_a, crt_b, crt_c;
  int n_bit, n_miss, ci_total, ci_test;
  double geno, x_mean;
  size_t c = 0;
  size_t n_size = UtY.shape[0], d_size = UtY.shape[1], c_size = UtW.shape[1];
  size_t dc_size = d_size * (c_size + 1), v_size = d_size * (d_size + 1) / 2;

  // Create a large matrix.
  size_t msize = LMM_BATCH_SIZE;
  DMatrix Xlarge; // = gsl_matrix_alloc(U->size1, msize);
  DMatrix UtXlarge; // = gsl_matrix_alloc(U->size1, msize);
  gsl_matrix_set_zero(Xlarge);

  // Large matrices for EM.
  DMatrix U_hat; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix E_hat; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix OmegaU; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix OmegaE; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiY; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiBX; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiU; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix UltVehiE; // = gsl_matrix_alloc(d_size, n_size);

  // Large matrices for NR.
  // Each dxd block is H_k^{-1}.
  DMatrix Hi_all; // = gsl_matrix_alloc(d_size, d_size * n_size);

  // Each column is H_k^{-1}y_k.
  DMatrix Hiy_all; // = gsl_matrix_alloc(d_size, n_size);

  // Each dcxdc block is x_k\otimes H_k^{-1}.
  DMatrix xHi_all; // = gsl_matrix_alloc(dc_size, d_size * n_size);

  DMatrix Hessian; // = gsl_matrix_alloc(v_size * 2, v_size * 2);

  DMatrix x; // = gsl_vector_alloc(n_size);

  DMatrix Y; // = gsl_matrix_alloc(d_size, n_size);
  DMatrix X; // = gsl_matrix_alloc(c_size + 1, n_size);
  DMatrix V_g; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix V_e; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix B; // = gsl_matrix_alloc(d_size, c_size + 1);
  DMatrix beta; // = gsl_vector_alloc(d_size);
  DMatrix Vbeta; // = gsl_matrix_alloc(d_size, d_size);

  // Null estimates for initial values.
  DMatrix V_g_null; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix V_e_null; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix B_null; // = gsl_matrix_alloc(d_size, c_size + 1);
  DMatrix se_B_null; // = gsl_matrix_alloc(d_size, c_size);

  //gsl_matrix_view
  DMatrix X_sub = get_sub_dmatrix(X, 0, 0, c_size, n_size);
  //gsl_matrix_view
  DMatrix B_sub = get_sub_dmatrix(B, 0, 0, d_size, c_size);
  //gsl_matrix_view
  DMatrix xHi_all_sub = get_sub_dmatrix(xHi_all, 0, 0, d_size * c_size, d_size * n_size);

  //gsl_matrix_transpose_memcpy(Y, UtY);
  //gsl_matrix_transpose_memcpyX_sub, UtW);

  //gsl_vector_view
  DMatrix X_row = get_row(X, c_size);
  //gsl_vector_set_zero(X_row);
  //gsl_vector_view
  DMatrix B_col = get_col(B, c_size);
  //gsl_vector_set_zero(B_col);

  MphInitial(em_iter, em_prec, nr_iter, nr_prec, eval, X_sub, Y, l_min,
             l_max, n_region, V_g, V_e, B_sub);

  logl_H0 = MphEM('R', em_iter, em_prec, eval, X_sub, Y, U_hat, E_hat,
                  OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU, UltVehiE, V_g,
                  V_e, B_sub);
  logl_H0 = MphNR('R', nr_iter, nr_prec, eval, X_sub, Y, Hi_all,
                  xHi_all_sub, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
  MphCalcBeta(eval, X_sub, Y, V_g, V_e, UltVehiY, B_sub,
              se_B_null);

  c = 0;
  Vg_remle_null = [];
  Ve_remle_null = [];
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      Vg_remle_null ~= V_g.accessor( i, j);
      Ve_remle_null ~= V_e.accessor( i, j);
      VVg_remle_null ~= Hessian.accessor( c, c);
      VVe_remle_null ~= Hessian.accessor( c + v_size, c + v_size);
      c++;
    }
  }
  beta_remle_null = [];
  se_beta_remle_null = [];
  for (size_t i = 0; i < se_B_null.shape[0]; i++) {
    for (size_t j = 0; j < se_B_null.shape[1]; j++) {
      beta_remle_null ~= B.accessor( i, j);
      se_beta_remle_null ~= se_B_null.accessor( i, j);
    }
  }
  logl_remle_H0 = logl_H0;

  writeln("REMLE estimate for Vg in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_g.accessor(i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Vg): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c, c)), "\t");
    }
    write("\n");
  }
  writeln("REMLE estimate for Ve in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_e.accessor( i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Ve): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c + v_size, c + v_size)), "\t");
    }
    write("\n");
  }
  writeln("REMLE likelihood = ", logl_H0);

  logl_H0 = MphEM('L', em_iter, em_prec, eval, X_sub, Y, U_hat, E_hat,
                  OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU, UltVehiE, V_g,
                  V_e, B_sub);
  logl_H0 = MphNR('L', nr_iter, nr_prec, eval, &X_sub, Y, Hi_all,
                  xHi_all_sub, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b,
                  crt_c);
  MphCalcBeta(eval, X_sub, Y, V_g, V_e, UltVehiY, B_sub, se_B_null);

  c = 0;
  Vg_mle_null = [];
  Ve_mle_null = [];
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      Vg_mle_null ~= V_g.accessor( i, j);
      Ve_mle_null ~= V_e.accessor( i, j);
      VVg_mle_null ~= Hessian.accessor( c, c);
      VVe_mle_null ~= Hessian.accessor( c + v_size, c + v_size);
      c++;
    }
  }
  beta_mle_null = [];
  se_beta_mle_null = [];
  for (size_t i = 0; i < se_B_null.shape[0]; i++) {
    for (size_t j = 0; j < se_B_null.shape[1]; j++) {
      beta_mle_null ~= B.accessor( i, j);
      se_beta_mle_null ~= se_B_null.accessor(i, j);
    }
  }
  logl_mle_H0 = logl_H0;

  writeln("MLE estimate for Vg in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_g.accessor(i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Vg): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c, c)), "\t");
    }
    write("\n");
  }
  writeln("MLE estimate for Ve in the null model: ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      write(V_e.accessor( i, j), "\t");
    }
    write("\n");
  }
  writeln("se(Ve): ");
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j <= i; j++) {
      c = GetIndex(i, j, d_size);
      write(sqrt(Hessian.accessor(c + v_size, c + v_size)), "\t");
    }
    write("\n");
  }
  writeln("MLE likelihood = ", logl_H0);

  double[] v_beta, v_Vg, v_Ve, v_Vbeta;
  for (size_t i = 0; i < d_size; i++) {
    v_beta ~= 0;
  }
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = i; j < d_size; j++) {
      v_Vg ~= 0;
      v_Ve ~= 0;
      v_Vbeta ~= 0;
    }
  }

  //gsl_matrix_memcpy(V_g_null, V_g);
  //gsl_matrix_memcpy(V_e_null, V_e);
  //gsl_matrix_memcpy(B_null, B);

  // Start reading genotypes and analyze.
  // Calculate n_bit and c, the number of bit for each snp.
  if (ni_total % 4 == 0) {
    n_bit = ni_total / 4;
  } else {
    n_bit = ni_total / 4 + 1;
  }

  // Print the first three magic numbers.
  for (int i = 0; i < 3; ++i) {
    infile.read(ch, 1);
    b = ch[0];
  }

  size_t csnp = 0, t_last = 0;
  for (size_t t = 0; t < indicator_snp.size(); ++t) {
    if (indicator_snp[t] == 0) {
      continue;
    }
    t_last++;
  }
  for (size_t t = 0; t < snpInfo.length; ++t) {
    if (indicator_snp[t] == 0) {
      continue;
    }

    // n_bit, and 3 is the number of magic numbers.
    infile.seekg(t * n_bit + 3);

    // read genotypes
    x_mean = 0.0;
    n_miss = 0;
    ci_total = 0;
    ci_test = 0;
    for (int i = 0; i < n_bit; ++i) {
      infile.read(ch, 1);
      b = ch[0];

      // Minor allele homozygous: 2.0; major: 0.0;
      for (size_t j = 0; j < 4; ++j) {
        if ((i == (n_bit - 1)) && ci_total == to!int(ni_total)) {
          break;
        }
        if (indicator_idv[ci_total] == 0) {
          ci_total++;
          continue;
        }

        if (b[2 * j] == 0) {
          if (b[2 * j + 1] == 0) {
            x.elements[ci_test] = 2;
            x_mean += 2.0;
          } else {
            x.elements[ci_test] = 1;
            x_mean += 1.0;
          }
        } else {
          if (b[2 * j + 1] == 1) {
            x.elements[ci_test] = 0;
          } else {
            x.elements[ci_test] = -9;
            n_miss++;
          }
        }

        ci_total++;
        ci_test++;
      }
    }

    x_mean /= to!double(ni_test - n_miss);

    for (size_t i = 0; i < ni_test; ++i) {
      geno = gsl_vector_get(x, i);
      if (geno == -9) {
        gsl_vector_set(x, i, x_mean);
        geno = x_mean;
      }
    }

    //gsl_vector_view
    DMatrix Xlarge_col = get_col(Xlarge, csnp % msize);
    //gsl_vector_memcpy(Xlarge_col, x);
    csnp++;

    if (csnp % msize == 0 || csnp == t_last) {
      size_t l = 0;
      if (csnp % msize == 0) {
        l = msize;
      } else {
        l = csnp % msize;
      }

      //gsl_matrix_view
      DMatrix Xlarge_sub = get_sub_dmatrix(Xlarge, 0, 0, Xlarge.shape[0], l);
      //gsl_matrix_view
      DMatrix UtXlarge_sub = get_sub_dmatrix(UtXlarge, 0, 0, UtXlarge.shape[0], l);

      UtXlarge_sub = matrix_mult(U.T, Xlarge_sub);

      gsl_matrix_set_zero(Xlarge);

      for (size_t i = 0; i < l; i++) {
        //gsl_vector_view
        DMatrix UtXlarge_col = gsl_matrix_column(UtXlarge, i);
        //gsl_vector_memcpy(X_row, UtXlarge_col);

        // Initial values.
        //gsl_matrix_memcpy(V_g, V_g_null);
        //gsl_matrix_memcpy(V_e, V_e_null);
        //gsl_matrix_memcpy(B, B_null);

        // 3 is before 1.
        if (a_mode == 3 || a_mode == 4) {
          p_score = MphCalcP(eval, X_row, X_sub, Y, V_g_null, V_e_null, UltVehiY, beta, Vbeta);

          if (p_score < p_nr && crt == 1) {
            logl_H1 = MphNR('R', 1, nr_prec * 10, eval, X, Y, Hi_all, xHi_all,
                            Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
            p_score = PCRT(3, d_size, p_score, crt_a, crt_b, crt_c);
          }
        }

        if (a_mode == 2 || a_mode == 4) {
          logl_H1 = MphEM('L', em_iter / 10, em_prec * 10, eval, X, Y, U_hat,
                          E_hat, OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU,
                          UltVehiE, V_g, V_e, B);

          // Calculate beta and Vbeta.
          p_lrt = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e,
                           UltVehiY, beta, Vbeta);
          p_lrt = gsl_cdf_chisq_Q(2.0 * (logl_H1 - logl_H0), to!double(d_size));

          if (p_lrt < p_nr) {
            logl_H1 =
                MphNR('L', nr_iter / 10, nr_prec * 10, eval, X, Y, Hi_all,
                      xHi_all, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);

            // Calculate beta and Vbeta.
            p_lrt = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);
            p_lrt = gsl_cdf_chisq_Q(2.0 * (logl_H1 - logl_H0), to!double(d_size));
            if (crt == 1) {
              p_lrt = PCRT(2, d_size, p_lrt, crt_a, crt_b, crt_c);
            }
          }
        }

        if (a_mode == 1 || a_mode == 4) {
          logl_H1 = MphEM('R', em_iter / 10, em_prec * 10, eval, X, Y, U_hat,
                          E_hat, OmegaU, OmegaE, UltVehiY, UltVehiBX, UltVehiU,
                          UltVehiE, V_g, V_e, B);
          p_wald = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e, UltVehiY, beta, Vbeta);

          if (p_wald < p_nr) {
            logl_H1 = MphNR('R', nr_iter / 10, nr_prec * 10, eval, X, Y, Hi_all,
                         xHi_all, Hiy_all, V_g, V_e, Hessian, crt_a, crt_b, crt_c);
            p_wald = MphCalcP(eval, X_row, X_sub, Y, V_g, V_e,
                              UltVehiY, beta, Vbeta);

            if (crt == 1) {
              p_wald = PCRT(1, d_size, p_wald, crt_a, crt_b, crt_c);
            }
          }
        }


        // Store summary data.
        for (size_t i = 0; i < d_size; i++) {
          v_beta[i] = beta.elements[i];
        }

        c = 0;
        for (size_t i = 0; i < d_size; i++) {
          for (size_t j = i; j < d_size; j++) {
            v_Vg[c] = V_g.accessor( i, j);
            v_Ve[c] = V_e.accessor( i, j);
            v_Vbeta[c] = Vbeta.accessor( i, j);
            c++;
          }
        }

        MPHSUMSTAT SNPs = {v_beta, p_wald, p_lrt, p_score, v_Vg, v_Ve, v_Vbeta};
        sumStat ~= SNPs;
      }
    }
  }

  return;
}

// 'R' for restricted likelihood and 'L' for likelihood.
// 'R' update B and 'L' don't.
// only calculate -0.5*\sum_{k=1}^n|H_k|-0.5yPxy.
double MphCalcLogL(const DMatrix eval, const DMatrix xHiy, const DMatrix D_l,
                   const DMatrix UltVehiY, const DMatrix Qi) {

  size_t n_size = eval.size, d_size = D_l.size, dc_size = Qi.shape[0];
  double logl = 0.0, delta, dl, y, d;

  // Calculate yHiy+log|H_k|.
  for (size_t k = 0; k < n_size; k++) {
    delta = gsl_vector_get(eval, k);
    for (size_t i = 0; i < d_size; i++) {
      y = UltVehiY.accessor(i, k);
      dl = D_l.elements[i];
      d = delta * dl + 1.0;

      logl += y * y / d + mlog(d);
    }
  }

  // Calculate the rest of yPxy.
  DMatrix Qiv; // = gsl_vector_alloc(dc_size);

  Qiv = matrix_mult(Qi, xHiy);
  d = vector_ddot(xHiy, Qiv);

  logl -= d;

  return -0.5 * logl;
}

// Qi=(\sum_{k=1}^n x_kx_k^T\otimes(delta_k*Dl+I)^{-1} )^{-1}.
double CalcQi(const DMatrix eval, const DMatrix D_l,
              const DMatrix X, DMatrix Qi) {
  size_t n_size = eval.size, d_size = D_l.size, dc_size = Qi.shape[0];
  size_t c_size = dc_size / d_size;

  double delta, dl, d1, d2, d, logdet_Q;

  DMatrix ; //Q = gsl_matrix_alloc(dc_size, dc_size);
  //gsl_matrix_set_zero(Q);

  for (size_t i = 0; i < c_size; i++) {
    for (size_t j = 0; j < c_size; j++) {
      for (size_t l = 0; l < d_size; l++) {
        dl = D_l.elements[l];

        if (j < i) {
          d = Q/accessor( j * d_size + l, i * d_size + l);
        } else {
          d = 0.0;
          for (size_t k = 0; k < n_size; k++) {
            d1 = X.accessor( i, k);
            d2 = X.accessor( j, k);
            delta = eval.elements[k];
            d += d1 * d2 / (dl * delta + 1.0); // @@
          }
        }

        Q.set(i * d_size + l, j * d_size + l, d);
      }
    }
  }

  // Calculate LU decomposition of Q, and invert Q and calculate |Q|.
  int sig;
  gsl_permutation *pmt = gsl_permutation_alloc(dc_size);
  LUDecomp(Q, pmt, &sig);
  LUInvert(Q, pmt, Qi);

  logdet_Q = LULndet(Q);

  gsl_permutation_free(pmt);

  return logdet_Q;
}

// xHiy=\sum_{k=1}^n x_k\otimes ((delta_k*Dl+I)^{-1}Ul^TVe^{-1/2}y.
void CalcXHiY(const DMatrix eval, const DMatrix D_l,
              const DMatrix X, const DMatrix UltVehiY,
              DMatrix xHiy) {
  size_t n_size = eval.size, c_size = X.shape[0], d_size = D_l.size;

  //gsl_vector_set_zero(xHiy);

  double x, delta, dl, y, d;
  for (size_t i = 0; i < d_size; i++) {
    dl = D_l.elements[i];
    for (size_t j = 0; j < c_size; j++) {
      d = 0.0;
      for (size_t k = 0; k < n_size; k++) {
        x = X.accessor(j, k);
        y = UltVehiY.accessor(i, k);
        delta = eval.elements[k];
        d += x * y / (delta * dl + 1.0);
      }
      xHiy.elements[j * d_size + i] = d;
    }
  }

  return;
}

// OmegaU=D_l/(delta Dl+I)^{-1}
// OmegaE=delta D_l/(delta Dl+I)^{-1}
void CalcOmega(const DMatrix eval, const DMatrix D_l,
               DMatrix OmegaU, DMatrix OmegaE) {
  size_t n_size = eval.size, d_size = D_l.size;
  double delta, dl, d_u, d_e;

  for (size_t k = 0; k < n_size; k++) {
    delta = eval.elements[k];
    for (size_t i = 0; i < d_size; i++) {
      dl = D_l.elements[i];

      d_u = dl / (delta * dl + 1.0);  // @@
      d_e = delta * d_u;

      OmegaU.set(i, k, d_u);
      OmegaE.set(i, k, d_e);
    }
  }

  return;
}

void UpdateL_B(const DMatrix X, const DMatrix XXti,
               const DMatrix UltVehiY, const DMatrix UltVehiU,
               DMatrix UltVehiBX, DMatrix UltVehiB) {
  size_t c_size = X.shape[0], d_size = UltVehiY.shape[0];

  DMatrix YUX; // = gsl_matrix_alloc(d_size, c_size);

  //gsl_matrix_memcpy(UltVehiBX, UltVehiY);
  //gsl_matrix_sub(UltVehiBX, UltVehiU);

  YUX = matrix_mult(UltVehiBX, X.T);
  UltVehiB = matrix_mult(YUX, XXti);

  return;
}

void UpdateRL_B(const DMatrix xHiy, const DMatrix Qi, DMatrix UltVehiB) {
  size_t d_size = UltVehiB.shape[0], c_size = UltVehiB.shape[1], dc_size = Qi.shape[0];

  // Calculate b=Qiv.
  DMatrix b = matrix_mult(Qi, xHiy);

  // Copy b to UltVehiB.
  for (size_t i = 0; i < c_size; i++) {
    //gsl_vector_view
    DMatrix UltVehiB_col = get_col(UltVehiB, i);
    //gsl_vector_const_view
    DMatrix b_subcol; // = gsl_vector_const_subvector(b, i * d_size, d_size);
    //gsl_vector_memcpy(UltVehiB_col, b_subcol);
  }
  return;
}

void UpdateU(const DMatrix OmegaE, const DMatrix UltVehiY,
             const DMatrix UltVehiBX, DMatrix UltVehiU) {
  //gsl_matrix_memcpy(UltVehiU, UltVehiY);
  UltVehiU = subtract_dmatrix(UltVehiU, UltVehiBX);
  UltVehiU = slow_multiply_dmatrix(UltVehiU, OmegaE);
  return;
}


void UpdateE(const DMatrix UltVehiY, const DMatrix UltVehiBX,
             const DMatrix UltVehiU, DMatrix UltVehiE) {
  //gsl_matrix_memcpy(UltVehiE, UltVehiY);
  UltVehiE = subtract_dmatrix(UltVehiE, UltVehiBX);
  UltVehiE = subtract_dmatrix(UltVehiE, UltVehiU);

  return;
}

void UpdateV(const DMatrix eval, const DMatrix U, const DMatrix E,
             const DMatrix Sigma_uu, const DMatrix Sigma_ee,
             DMatrix V_g, DMatrix V_e) {
  size_t n_size = eval.size, d_size = U.shape[0];

  V_g = zeros_dmatrix(V_g.shape[0], V_g.shape[1]);
  V_e = zeros_dmatrix(V_e.shape[0], V_e.shape[1]);

  double delta;

  // Calculate the first part: UD^{-1}U^T and EE^T.
  for (size_t k = 0; k < n_size; k++) {
    delta = eval.elements[k];
    if (delta == 0) {
      continue;
    }

    //gsl_vector_const_view
    DMatrix U_col = get_col(U, k);
    // IMP
    //gsl_blas_dsyr(CblasUpper, 1.0 / delta, &U_col.vector, V_g);
  }

  // IMP
  //gsl_blas_dsyrk(CblasUpper, CblasNoTrans, 1.0, E, 0.0, V_e);

  // Copy the upper part to lower part.
  for (size_t i = 0; i < d_size; i++) {
    for (size_t j = 0; j < i; j++) {
      V_g.set(i, j, V_g.accessor(j, i));
      V_e.set(i, j, V_e.accessor(j, i));
    }
  }

  // Add Sigma.
  V_g = add_dmatrix(V_g, Sigma_uu);
  V_e = add_dmatrix(V_e, Sigma_ee);

  // Scale by 1/n.
  V_g = multiply_dmatrix_num(V_g, 1.0 / to!double(n_size));
  V_e = multiply_dmatrix_num(V_e, 1.0 / to!double(n_size));

  return;
}

void CalcSigma(const char func_name, const DMatrix eval,
               const DMatrix D_l, const DMatrix X,
               const DMatrix OmegaU, const DMatrix OmegaE,
               const DMatrix UltVeh, const DMatrix Qi,
               DMatrix Sigma_uu, DMatrix Sigma_ee) {
  if(func_name != 'R' && func_name != 'L' && func_name != 'r' && func_name != 'l') {
    writeln("func_name only takes 'R' or 'L': 'R' for log-restricted likelihood, 'L' for log-likelihood.");
    return;
  }

  size_t n_size = eval.size, c_size = X.shape[0];
  size_t d_size = D_l.size, dc_size = Qi.shape[0];

  gsl_matrix_set_zero(Sigma_uu);
  gsl_matrix_set_zero(Sigma_ee);

  double delta, dl, x, d;

  // Calculate the first diagonal term.
  //gsl_vector_view
  DMatrix Suu_diag = get_diagonal(Sigma_uu);
  //gsl_vector_view
  DMatrix See_diag = get_diagonal(Sigma_ee);

  for (size_t k = 0; k < n_size; k++) {
    //gsl_vector_const_view
    DMatrix OmegaU_col = get_col(OmegaU, k);
    //gsl_vector_const_view
    DMatrix OmegaE_col = get_col(OmegaE, k);

    Suu_diag = add_dmatrix(Suu_diag, OmegaU_col);
    Suu_diag = add_dmatrix(See_diag, OmegaE_col);
  }

  // Calculate the second term for REML.
  if (func_name == 'R' || func_name == 'r') {
    DMatrix M_u; // = gsl_matrix_alloc(dc_size, d_size);
    DMatrix M_e; // = gsl_matrix_alloc(dc_size, d_size);
    DMatrix QiM; // = gsl_matrix_alloc(dc_size, d_size);

    M_u = zeros_dmatrix(M_u.shape[0], M_u.shape[1]);
    M_e = zeros_dmatrix(M_e.shape[0], M_e.shape[1]);

    for (size_t k = 0; k < n_size; k++) {
      delta = eval.elements[k];

      for (size_t i = 0; i < d_size; i++) {
        dl =D_l.elements[i];
        for (size_t j = 0; j < c_size; j++) {
          x = X.accessor(j, k);
          d = x / (delta * dl + 1.0);
          M_e.set(j * d_size + i, i, d);
          M_u.set(j * d_size + i, i, d * dl);
        }
      }
      QiM = matrix_mult(Qi, M_u);
      // IMP : note delta scaling
      //matrix_mult(CblasTrans, CblasNoTrans, delta, M_u, QiM, 1.0, Sigma_uu);

      QiM = matrix_mult(Qi, M_e);
      Sigma_ee = matrix_mult(M_e.T, QiM);
    }
  }

  // Multiply both sides by VehUl.
  DMatrix M = matrix_mult(Sigma_uu, UltVeh);
  Sigma_uu = matrix_mult(UltVeh.T, M);
  M = matrix_mult(Sigma_ee, UltVeh);
  Sigma_ee = matrix_mult(UltVeh.T, M);

  return;
}

// Calculate all Hi and return logdet_H=\sum_{k=1}^{n}log|H_k|
// and calculate Qi and return logdet_Q
// and calculate yPy.
void CalcHiQi(const DMatrix eval, const DMatrix X,
              const DMatrix V_g, const DMatrix V_e, DMatrix Hi_all,
              DMatrix Qi, double logdet_H, double logdet_Q) {
  Hi_all = zeros_dmatrix(Hi_all.shape[0], Hi_all.shape[1]);
  Qi = zeros_dmatrix(Qi.shape[0], Qi.shape[1]);
  logdet_H = 0.0;
  logdet_Q = 0.0;

  size_t n_size = eval.size, c_size = X.shape[0], d_size = V_g.shape[0];
  double logdet_Ve = 0.0, delta, dl, d;

  DMatrix mat_dd; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVeh; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix UltVehi; // = gsl_matrix_alloc(d_size, d_size);
  DMatrix D_l; // = gsl_vector_alloc(d_size);

  // Calculate D_l, UltVeh and UltVehi.
  logdet_Ve = EigenProc(V_g, V_e, D_l, UltVeh, UltVehi);

  // Calculate each Hi and log|H_k|.
  logdet_H = to!double(n_size) * logdet_Ve;
  for (size_t k = 0; k < n_size; k++) {
    delta = eval.elements[k];

    //gsl_matrix_memcpy(mat_dd, UltVehi);
    for (size_t i = 0; i < d_size; i++) {
      dl = gsl_vector_get(D_l, i);
      d = delta * dl + 1.0;

      //gsl_vector_view
      DMatrix mat_row = get_row(mat_dd, i);
      mat_row = divide_dmatrix_num(mat_row, d); // @@

      logdet_H += mlog(d);
    }

    //gsl_matrix_view
    DMatrix Hi_k = get_sub_dmatrix(Hi_all, 0, k * d_size, d_size, d_size);
    Hi_k = matrix_mult(UltVehi.T, mat_dd);
  }

  // Calculate Qi, and multiply I\o times UtVeh on both side and
  // calculate logdet_Q, don't forget to substract
  // c_size*logdet_Ve.
  logdet_Q = CalcQi(eval, D_l, X, Qi) - to!double(c_size) * logdet_Ve;

  for (size_t i = 0; i < c_size; i++) {
    for (size_t j = 0; j < c_size; j++) {
      //gsl_matrix_view
      DMatrix Qi_sub = get_sub_dmatrix(Qi, i * d_size, j * d_size, d_size, d_size);
      if (j < i) {
        //gsl_matrix_view
        DMatrix Qi_sym = get_sub_dmatrix(Qi, j * d_size, i * d_size, d_size, d_size);
        //gsl_matrix_transpose_memcpy(&Qi_sub.matrix, &Qi_sym.matrix);
      } else {
        mat_dd = matrix_mult(Qi_sub, UltVeh);
        Qi_sub = matrix_mult(UltVeh.T, mat_dd);
      }
    }
  }

  return;
}


// Calculate all Hiy.
void Calc_Hiy_all(const DMatrix Y, const DMatrix Hi_all, DMatrix Hiy_all) {
  Hiy_all = zeros_dmatrix(Hiy_all.shape[0], Hiy_all.shape[1]);

  size_t n_size = Y.shape[1], d_size = Y.shape[0];

  for (size_t k = 0; k < n_size; k++) {
    //gsl_matrix_const_view
    DMatrix Hi_k = get_sub_dmatrix(Hi_all, 0, k * d_size, d_size, d_size);
    //gsl_vector_const_view
    DMatrix y_k = get_col(Y, k);
    //gsl_vector_view
    DMatrix Hiy_k = gsl_matrix_column(Hiy_all, k);

    Hiy_k = matrix_mult(Hi_k, y_k.vector);
  }

  return;
}
