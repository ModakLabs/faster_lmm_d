module simplelmm.gwas;
import std.parallelism : taskPool;
import std.stdio;
import std.typecons;
import simplelmm.lmm2;
import simplelmm.dmatrix;
import dstats.distrib;
import simplelmm.optmatrix;

void compute_snp(int j,int n,double[] snps,LMM2 lmmobject, bool REML,double q){
  writeln("In compute_snp");
  double[] result;
  int rows = cast(int)(snps.length)/n;
  for(int i = 0; i< rows; i++){
    double[] snp = snps[i*j..(i+1)*j];
    dmatrix x = dmatrix([n,1], snp); //all the SNPs
    //ts,ps,beta,betaVar = 
    double a = 0;
    //lmm2association(lmmobject, x, a, REML,true);
    //result.append( (ts,ps) );
  }
}

//void f_init(q){
//  compute_snp.q = q;
//}

auto gwas(double[] Y, ref dmatrix G, ref dmatrix K, bool restricted_max_likelihood = true, bool refit=false, bool verbose = true){
  //"""
  //GWAS. The G matrix should be n inds (cols) x m snps (rows)
  //"""
  writeln("In gwas.gwas");
  //# matrix_initialize()
  //cpu_num = mp.cpu_count();
  //if(threads.numThreads){
  int cpu_num = std.parallelism.totalCPUs;
  cpu_num = 1;
  //}
        
  //if(gwas_useCUDA(G)){
  //  cpu_num = 1;
  //}
      
  writefln("Using %u threads", cpu_num);

  bool kfile2 = false;
  bool reml = restricted_max_likelihood;

  //writeln("G",G);
  //G = matrixTranspose(G);
  int n = G.shape[1]; // inds
  int inds = n;
  int m = G.shape[0]; // snps
  int snps = m;
  writefln("%d SNPs",snps);
  if(snps<inds){
    writefln("snps should be larger than inds (snps=%d,inds=%d)", snps,inds);
  }

  //# CREATE LMM object for association
  //# if not kfile2:  L = LMM(Y,K,Kva,Kve,X0,verbose=verbose)
  //# else:  L = LMM_withK2(Y,K,Kva,Kve,X0,verbose=verbose,K2=K2)
  dmatrix Kva;
  dmatrix Kve;
  dmatrix X0;

  LMM2 lmm2 = LMM2(Y,K,Kva,Kve,X0, true);
  //writeln(lmm2);
  dmatrix X;
  if(!refit){
    writeln("Computing fit for null model");
    double fit_hmax,fit_sigma;
    dmatrix fit_beta;
    double fit_LL;
    lmm2fit(fit_hmax,fit_beta,fit_sigma,fit_LL, lmm2, X,100,true); // # follow GN model in run_other;
    writeln("heritability= ", lmm2.optH, " sigma= ", lmm2.optSigma, " LL= ", fit_LL);
  }

  double[] res;
  int q;
  double[] collect; //# container for SNPs to be processed in one batch
  //writeln(collect);
  int count = 0;
  int job = 0;
  int jobs_running = 0;
  int jobs_completed = 0;

  double[] ps;
  double[] ts;

  for(int i=0; i<m; i++){
    dmatrix x = getRow(G, i);
    x.shape = [n,1];
    double a = 0;
    double psNum, tsNum;
    lmm2association(psNum, tsNum,lmm2, x, a, true,true);
    a++;
    ps ~= psNum;
    ts ~= tsNum;
  }
  return Tuple!(double[], double[])(ts,ps);
}
