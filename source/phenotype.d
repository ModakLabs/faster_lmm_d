module faster_lmm_d.phenotype;
import faster_lmm_d.dmatrix;
import faster_lmm_d.helpers;
import std.stdio;

struct phenoStruct{
  double[] Y;
  bool[] keep;
  int n;

  this(double[] Y, bool[] keep, int n){
    this.Y = Y;
    this.keep = keep;
    this.n = n;
  }
}

phenoStruct remove_missing( int n, double[] y){
  //"""
  //Remove missing data. Returns new n,y,keep
  //"""
  writeln("In remove missing new");
  bool[] v = isnan(y);
  bool[] keep = negateBool(v);
  //if v.sum():
  //    info("runlmm.py: Cleaning the phenotype vector by removing %d individuals" % (v.sum()))
  double[] Y = getNumArray(y,keep);
  n = cast(int)Y.length;
  return phenoStruct(Y, keep, n);
}
