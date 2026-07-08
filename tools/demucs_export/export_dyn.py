import math, torch, warnings; warnings.filterwarnings("ignore")
import torch.nn.functional as F
from fractions import Fraction
import demucs.htdemucs as ht
from realstft import spectro_real, ispectro_real
from demucs.pretrained import get_model

def _spec_real(self,x):
    hl=self.hop_length; nfft=self.nfft
    le=int(math.ceil(x.shape[-1]/hl)); pad=hl//2*3
    x=ht.pad1d(x,(pad, pad+le*hl-x.shape[-1]),mode="reflect")
    z=spectro_real(x,nfft,hl)[..., :-1, :, :]; z=z[..., 2:2+le, :]; return z
def _ispec_real(self,z,length=None,scale=0):
    hl=self.hop_length//(4**scale)
    z=F.pad(z,(0,0,0,0,0,1)); z=F.pad(z,(0,0,2,2))
    pad=hl//2*3; le=hl*int(math.ceil(length/hl))+2*pad
    x=ispectro_real(z,hl,length=le); return x[..., pad:pad+length]
def _magnitude_real(self,z):
    B,C,Fr,T,_=z.shape; return z.permute(0,1,4,2,3).reshape(B,C*2,Fr,T)
def _mask_real(self,z,m):
    B,S,C,Fr,T=m.shape; return m.view(B,S,-1,2,Fr,T).permute(0,1,2,4,5,3).contiguous()

import demucs.hdemucs as _hd
def _pad1d_clean(x, paddings, mode="constant", value=0.):
    length=x.shape[-1]; pl,pr=paddings
    if mode=="reflect":
        mx=max(pl,pr)
        if length<=mx:
            extra=mx-length+1; epr=min(pr,extra); epl=extra-epr
            paddings=(pl-epl,pr-epr); x=F.pad(x,(epl,epr))
    return F.pad(x,paddings,mode,value)
_hd.pad1d=_pad1d_clean; ht.pad1d=_pad1d_clean
m=get_model('htdemucs_6s').models[0].eval()
m.segment=Fraction(3500,1000)
cls=type(m); cls._spec=_spec_real; cls._ispec=_ispec_real; cls._magnitude=_magnitude_real; cls._mask=_mask_real
L=int(3.5*m.samplerate); x=(torch.rand(1,2,L)-0.5)*0.3
with torch.no_grad(): ref=m(x)
try:
    torch.onnx.export(m,(x,),"demucsv4_3p5s.onnx",input_names=["input"],output_names=["output"],dynamo=True,opset_version=18)
    print("DYNAMO_OK")
except Exception as e:
    print("DYNAMO_FAIL",type(e).__name__,str(e)[:500])
import os
if os.path.exists("demucsv4_3p5s.onnx"):
    import numpy as np, onnxruntime as ort
    s=ort.InferenceSession("demucsv4_3p5s.onnx",providers=["CPUExecutionProvider"])
    o=s.run(None,{s.get_inputs()[0].name:x.numpy()})[0]
    print("onnx maxdiff vs torch",float(np.abs(o-ref.numpy()).max()),"shape",o.shape)
