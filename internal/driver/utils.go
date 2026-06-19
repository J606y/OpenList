package driver

import (
	"context"
	"io"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/stream"
)

type UpdateProgress = model.UpdateProgress

type RateLimitReader = stream.RateLimitReader

type RateLimitWriter = stream.RateLimitWriter

func NewLimitedUploadStream(ctx context.Context, r io.Reader) *RateLimitReader {
	return &RateLimitReader{
		Reader:  r,
		Limiter: stream.ServerUploadLimit,
		Ctx:     ctx,
	}
}

type ReaderUpdatingProgress = stream.ReaderUpdatingProgress

type SimpleReaderWithSize = stream.SimpleReaderWithSize
