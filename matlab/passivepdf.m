%
%########################################################################
%  read and plot passive scalar pdf's
%########################################################################
%
%
clear all;


fid=fopen('/scratch2/taylorm/tmix256C/tmix256C0001.1000.spdf','r','l');
%fid=fopen('../src/temp0000.0000.spdf','r','l');

time=fread(fid,1,'float64');
npmax=fread(fid,1,'float64');         
disp(sprintf('npassive = %i',npmax))

figure(1); clf; subplot(5,2,1)

np=1;
for p=1:npmax
   [n_del,delta,bin_size,n_bin,n_call,bins,pdf]=read1pdf(fid);
   %if (p==np) break; end;

   s2=sum(pdf.*bins.^2);
   mx=max(bins - bins.*(pdf==0));
   mn=min(bins - bins.*(pdf==0));        % min over non zero values
   
   subplot(5,2,p) 
   plot(bins,pdf)
   ax=axis;
   axis([-.5,1.5,ax(3),.2]);
   xlabel(sprintf('[%.3f,%.3f] <s^2>=%.5f',mn,mx,s2));
   set(gca,'YTickLabel','')    
   if (p==1) 
      title(sprintf('t=%.4f',time)); 
   end

   

end
times=sprintf('%.4f',time+10000);
times=times(2:length(times));
orient tall
print('-dpsc',['ppdf',times,'.ps']); 
print('-djpeg',['ppdf',times,'.jpg']); 
