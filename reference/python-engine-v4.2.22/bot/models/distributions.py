from __future__ import annotations
import math
import numpy as np
from scipy.stats import poisson, nbinom

def clamp(x,a=1e-9,b=1-1e-9): return max(a,min(b,float(x)))

def dixon_coles_tau(i,j,lam_h,lam_a,rho=-0.055):
    if i==0 and j==0: return 1-lam_h*lam_a*rho
    if i==0 and j==1: return 1+lam_h*rho
    if i==1 and j==0: return 1+lam_a*rho
    if i==1 and j==1: return 1-rho
    return 1.0

def dixon_coles_matrix(lam_h,lam_a,rho=-0.055,max_goals=12):
    lh=max(1e-8,float(lam_h)); la=max(1e-8,float(lam_a))
    n=max_goals+1
    m=np.outer(poisson.pmf(np.arange(n),lh),poisson.pmf(np.arange(n),la))
    for i in range(min(2,n)):
        for j in range(min(2,n)):
            m[i,j]*=dixon_coles_tau(i,j,lh,la,rho)
    s=m.sum()
    return m/s if s else m

def outcome_probs(m):
    return float(np.tril(m,-1).sum()), float(np.trace(m)), float(np.triu(m,1).sum())

def fair(p): return 1.0/max(float(p),1e-9)

def nb_pmf(mu,var,max_k=60):
    mu=max(float(mu),1e-9); var=max(float(var),mu+1e-9)
    r=mu*mu/(var-mu); p=r/(r+mu)
    x=np.arange(max_k+1); pmf=nbinom.pmf(x,r,p); return pmf/pmf.sum()
