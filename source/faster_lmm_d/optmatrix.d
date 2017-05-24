/*
   This code is part of faster_lmm_d and published under the GPLv3
   License (see LICENSE.txt)

   Copyright © 2017 Prasun Anand & Pjotr Prins
*/

module faster_lmm_d.optmatrix;

import std.experimental.logger;
import std.math: sqrt, round;
import std.stdio;
import std.typecons; // for Tuples

import cblas : gemm, Transpose, Order;

version(CUDA) {
  import faster_lmm_d.cuda;
}

import faster_lmm_d.dmatrix;
import faster_lmm_d.helpers;

extern (C) {
  int LAPACKE_dgetrf (int matrix_layout, int m, int n, double* a, int lda, int* ipiv);
  int LAPACKE_dsyevr (int matrix_layout, char jobz, char range, char uplo, int n,
                      double* a, int lda, double vl, double vu, int il, int iu, double abstol,
                      int* m, double* w, double* z, int ldz, int* isuppz);
  int LAPACKE_dgetri (int matrix_layout, int n, double* a, int lda, const(int)* ipiv);
}

DMatrix matrix_mult(const DMatrix lha,const DMatrix rha) {
  double[] C = new double[lha.rows()*rha.cols()];
  gemm(Order.RowMajor, Transpose.NoTrans, Transpose.NoTrans, cast(int)lha.rows(), cast(int)rha.cols(), cast(int)lha.cols(), /*no scaling*/
       1,lha.elements.ptr, cast(int)lha.cols(), rha.elements.ptr, cast(int)rha.cols(), /*no addition*/0, C.ptr, cast(int)rha.cols());
  auto res_shape = [lha.rows(),rha.cols()];
  return DMatrix(res_shape, C);
}

DMatrix matrix_mult_transpose(const DMatrix lha, const DMatrix rha) {
  double[] C = new double[lha.rows()*rha.rows()];
  gemm(Order.RowMajor, Transpose.NoTrans, Transpose.NoTrans, cast(int)lha.rows(), cast(int)rha.rows(), cast(int)lha.cols(), /*no scaling*/
       1,lha.elements.ptr, cast(int)lha.cols(), rha.elements.ptr, cast(int)rha.rows(), /*no addition*/0, C.ptr, cast(int)rha.rows());
  auto res_shape = [lha.rows(),rha.rows()];
  return DMatrix(res_shape, C);
}

DMatrix matrix_transpose(const DMatrix input) {
  m_items total_elements = input.size();
  auto dim = total_elements;
  double[] output = new double[total_elements];
  auto index = 0;
  m_items cols = input.cols();
  m_items rows = input.rows();
  for(auto i=0; i < cols; i++) {
    for(auto j=0; j < rows; j++) {
      output[index] = input.elements[j*cols + i];
      index++;
    }
  }
  return DMatrix([cols, rows],output);
}

void pretty_print(const DMatrix input) {
  m_items cols = input.cols();
  m_items rows = input.rows();
  writeln("[");
  if(rows>6) {
    for(auto i=0; i < 3; i++) {
      writeln(input.elements[(cols*i)..(cols*(i+1))]);
    }
    writeln("...");
    for(auto i = rows - 3; i < rows; i++) {
      writeln(input.elements[(cols*i)..(cols*(i+1))]);
    }
  }
  else{
    for(auto i = 0; i < rows; i++) {
      writeln(input.elements[(cols*i)..(cols*(i+1))]);
    }
  }

  writeln("]");
}

DMatrix slice_dmatrix(const DMatrix input, const ulong[] along) {
  trace("In slice_dmatrix");
  double[] output;
  foreach(row_index; along) {
    for(auto i=cast(ulong)(row_index*input.cols()); i < (row_index+1)*input.cols(); i++) {
      output ~= input.elements[i];
    }
  }
  return DMatrix([along.length,input.cols()],output);
}

DMatrix slice_dmatrix_keep(const DMatrix input, const bool[] along) {
  trace("In slice_dmatrix_keep");
  assert(along.length == input.rows());
  m_items cols = input.cols();
  double[] output;
  auto row_index = 0;
  auto shape0 = 0;
  foreach(bool toKeep; along) {
    if(toKeep) {
      for(auto i=row_index*cols; i < (row_index+1)*cols; i++) {
        output ~= input.elements[i];
      }
      shape0++;
    }
    row_index++;

  }
  return DMatrix([shape0,cols],output);
}

DMatrix normalize_along_row(const DMatrix input) {
  double[] largeArr;
  double[] arr;
  log(input.shape);
  m_items rows = input.rows();
  m_items cols = input.cols();
  for(auto i = 0; i < rows; i++) {
    arr = input.elements[(cols*i)..(cols*(i+1))].dup;
    bool[] missing = is_nan(arr);
    bool[] values_arr = negate_bool(missing);
    double[] values = get_num_array(arr,values_arr);
    double mean = global_mean(values);
    double variation = get_variation(values, mean);
    double std_dev = sqrt(variation);

    double[] num_arr = replace_nan(arr, values_arr, mean);
    if(std_dev == 0) {
      foreach(ref elem; num_arr) {
        elem -= mean;
      }
    }else{
      foreach(ref elem; num_arr) {
        elem = (elem - mean) / std_dev;
      }
    }
    largeArr ~= num_arr;
  }
  return DMatrix(input.shape, largeArr);
}

DMatrix remove_cols(const DMatrix input, const bool[] keep) {
  immutable col_length = sum(cast(bool[])keep);
  m_items rows = input.rows();
  m_items cols = input.cols();
  double[] arr = new double[rows*col_length];
  auto index = 0;
  for(auto i= 0; i < rows; i++) {
    for(auto j = i*cols, count = 0; j < (i+1)*cols; j++) {
      if(keep[count] == true) {
        arr[index] = input.elements[j];
        index++;
      }
      count++;
    }
  }
  auto shape = [rows, col_length];
  return DMatrix(shape, arr);
}

double[] rounded_nearest(const double[] input) {
  m_items total_elements = input.length;
  double[] arr = new double[total_elements];
  for(auto i = 0; i < total_elements; i++) {
    arr[i] = round(input[i]*1000)/1000;
  }
  return arr;
}

DMatrix rounded_nearest(const DMatrix input) {
  m_items total_elements = input.elements.length;
  double[] arr = new double[total_elements];
  for(auto i = 0; i < total_elements; i++) {
    arr[i] = round(input.elements[i]*1000)/1000;
  }
  return DMatrix(input.shape, arr);
}

//Obtain eigendecomposition for K and return Kva,Kve where Kva is cleaned
//of small values < 1e-6 (notably smaller than zero)

alias Tuple!(DMatrix,"kva",DMatrix,"kve") EighTuple;

EighTuple eigh(const DMatrix input) {
  double[] z = new double[input.rows() * input.cols()]; //eigenvalues
  double[] w = new double[input.rows()];  // eigenvectors
  double[] elements = input.elements.dup;

  double wi;
  int n = cast(int)input.rows();
  double vu, vl;
  int[] m = new int[n];
  int[] isuppz = new int[2*n];
  int il = 1;
  int iu = cast(int)input.cols();
  int ldz = n;
  double abstol = 0.001; //default value for abstol

  LAPACKE_dsyevr(101, 'V', 'A', 'L', n,
                elements.ptr, n, vl, vu, il, iu, abstol,
                m.ptr, w.ptr, z.ptr, ldz, isuppz.ptr);

  DMatrix kva = DMatrix([n,1], w);
  DMatrix kve = DMatrix(input.shape, z);
  for(auto zq = 0 ; zq < kva.elements.length; zq++){
    if(kva.elements[zq]< 1e-6){
      kva.elements[zq] = 0;
    }
  }
  EighTuple e;
  e.kva = kva;
  e.kve = kve;
  return e;
}

double det(const DMatrix input)
in {
  assert(input.is_square, "Input matrix should be square");
}
body {
  m_items rows = input.rows;
  m_items cols = input.cols;
  auto rf = getrf(input.elements, cols);
  auto pivot = rf[0];
  auto m2 = cast(immutable(double[]))rf[1];

  auto num_perm = 0;
  auto j = 0;
  foreach(swap; pivot) {
    if (swap-1 != j) num_perm += 1;
    j++;
  }
  // odd permutations => negative:
  double prod = (num_perm % 2 == 1.0 ? 1 : -1.0 );
  auto min = ( rows < cols ? rows : cols );
  for(auto i =0; i < min; i++) {
    prod *= m2[cols*i + i];
  }
  return prod;
}

Tuple!(immutable(int[]),immutable(double[])) getrf(const double[] arr, const m_items cols) {
  auto arr2 = arr.dup;
  auto ipiv = new int[cols+1];
  int i_cols = cast(int)cols;
  LAPACKE_dgetrf(101,i_cols,i_cols,arr2.ptr,i_cols,ipiv.ptr);
  return Tuple!(immutable(int[]),immutable(double[]))(cast(immutable(int[]))ipiv,cast(immutable(double[]))arr2);
}

DMatrix inverse(const DMatrix input) {
  m_items total_elements = input.size();
  m_items rows = input.rows();
  double[] elements= input.elements.dup; // exactly, elements get changed by LAPACK
  auto lwork = rows * rows;
  double[] work = new double[rows*rows];
  auto ipiv = new int[rows+1];
  auto result = new double[total_elements];
  int info;
  int output = LAPACKE_dgetrf(101, cast(int)rows,cast(int)rows,elements.ptr,cast(int)rows,ipiv.ptr);
  LAPACKE_dgetri(101, cast(int)rows, elements.ptr, cast(int)rows, ipiv.ptr);
  return DMatrix(input.shape, elements);
}

import std.conv;

unittest{
  DMatrix d1 = DMatrix([3,4],[2,4,5,6, 7,8,9,10, 2,-1,-4,3]);
  DMatrix d2 = DMatrix([4,2],[2,7,8,9, -5,2,-1,-4]);
  DMatrix d3 = DMatrix([3,2], [5,36,23, 99,13,-15]);
  assert(matrix_mult(d1,d2) == d3);

  DMatrix d4 = DMatrix([2,2], [2, -1, -4, 3]);
  DMatrix d5 = DMatrix([2,2], [1.5, 0.5, 2, 1]);
  assert(inverse(d4) == d5);

  DMatrix d6 = DMatrix([2,2],[2, -4, -1, 3]);
  assert(matrix_transpose(d4) == d6);

  DMatrix m = DMatrix([3,4],[10, 11, 12, 13,
                             14, 15, 16, 17,
                             18, 19, 20, 21]);

  DMatrix matrix = DMatrix([4,3],[10,14,18,
                              11,15,19,
                              12,16,20,
                              13,17,21]);

  auto transposed_mat = matrix_transpose(m);
  auto result_mat = matrix_transpose(matrix);
  assert(transposed_mat == matrix,to!string(transposed_mat));
  assert(result_mat == m,to!string(result_mat));

  DMatrix d7 = DMatrix([4,2],[-3,13,7, -5, -12, 26, 2, -8]);
  assert(matrix_mult_transpose(d2, d6) == d7);

  assert(det(d4) == 2,to!string(det(d4)));

  auto d8 = DMatrix([3,3], [21, 14, 12, -11, 22, 1, 31, -11, 42]);
  auto eigh_matrix = eigh(d8);
  auto kva_matrix = DMatrix([3, 1], [0, 17.322, 69.228]);
  auto kve_matrix = DMatrix([3, 3], [-0.823, 0.075, 0.563, -0.126, 0.943, -0.310, 0.554, 0.326, 0.766]);
  assert( rounded_nearest(eigh_matrix.kva) == kva_matrix);
  assert( rounded_nearest(eigh_matrix.kve) == kve_matrix);

  auto mat = DMatrix([3,3], [4,  6,  11,
                             5,  5,  5,
                             11, 12, 13]);

  auto rmMat = DMatrix([3,1], [11,
                                5,
                               13]);
  assert(remove_cols(mat, [false, false, true]) == rmMat);

  auto sliced_mat = DMatrix([2,3], [4, 6, 11,
                                   5, 5, 5, ]);

  assert(slice_dmatrix(mat, [0,1]) == sliced_mat);
  assert(slice_dmatrix_keep(mat, [true, true, false]) == sliced_mat);

  auto norm_mat = DMatrix([3,3], [-1.01905, -0.339683, 1.35873,
                                        0,         0,       0,
                                 -1.22474,         0, 1.22474]);
  assert(eqeq(normalize_along_row(mat), norm_mat));
}
